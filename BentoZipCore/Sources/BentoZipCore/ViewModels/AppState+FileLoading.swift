import Foundation

extension AppState {

    // MARK: - Background Task Lifecycle

    /// Cancel all in-flight window-local background loading, sizing, child-enumeration, browse-listing, and recent-archive tasks.
    /// Does NOT cancel running transfer tasks (compress/extract/mutate) managed by `TransferManager`.
    public func cancelBackgroundTasks() {
        _ = cancelLoadAndSizingTasks()
        coordinator.cancelBrowse()
        recentValidationTask?.cancel()
        recentValidationTask = nil
        activeConflictPrompt?.cancel()
        activeConflictPrompt = nil
        isLoading = false
        browseProgress = nil
        browseStage = .normal
        browseProcessedBytes = 0
        browseTotalBytes = 0
        isCalculatingSizes = false
    }

    @discardableResult
    private func cancelLoadAndSizingTasks() -> UInt64 {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        pendingAddedURLs.removeAll()
        sizeCalculationTask?.cancel()
        sizeCalculationTask = nil
        pendingSizeTargets.removeAll()
        isCalculatingSizes = false
        loadingChildTasks.values.forEach { $0.cancel() }
        loadingChildTasks.removeAll()
        return loadGeneration
    }

    private func updateLoadingStateIfIdle(generation: UInt64) {
        guard loadGeneration == generation else { return }
        if loadTask == nil && pendingAddedURLs.isEmpty {
            isLoading = false
        }
        if sizeCalculationTask == nil && pendingSizeTargets.isEmpty {
            isCalculatingSizes = false
        }
    }

    // MARK: - Loading & Staging Local Files

    /// Load local files or directories into compress mode without blocking the main actor.
    /// Top-level items appear immediately; folder contents load lazily on expansion, and folder
    /// byte sizes stream in on a low-priority background task in-place without tree copies.
    public func loadFiles(from urls: [URL]) {
        let generation = cancelLoadAndSizingTasks()
        loadTask = Task { [weak self] in
            await self?.runLoadFiles(from: urls, generation: generation)
        }
    }

    /// Async variant of `loadFiles(from:)` suitable for awaiting completion in callers and tests.
    public func loadFilesAsync(from urls: [URL]) async {
        let generation = cancelLoadAndSizingTasks()
        let task = Task<Void, Never> { [weak self] in
            await self?.runLoadFiles(from: urls, generation: generation)
        }
        loadTask = task
        await task.value
        await waitForPendingWork(generation: generation)
    }

    private func runLoadFiles(from urls: [URL], generation: UInt64) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        defer {
            if loadGeneration == generation {
                loadTask = nil
                updateLoadingStateIfIdle(generation: generation)
            }
        }

        clearNavigationAndSelection()
        lastError = nil
        sourceArchiveURL = nil
        archivePackedSize = nil
        archivePassword = nil
        cancelPasswordPrompt()
        replaceRootNodes([])
        mode = .compress
        showInspector = true
        isLoading = true

        let shallowEntries = await FileUtils.buildShallowEntriesAsync(from: urls)
        guard !Task.isCancelled, loadGeneration == generation else {
            return
        }

        let nodes = shallowEntries.map { FileNode(entry: $0) }
        let directoryTargets = nodes.filter(\.isDirectory).map { ($0.id, $0.url) }
        replaceRootNodes(nodes)
        isLoading = false

        if !directoryTargets.isEmpty {
            enqueueSizeCalculation(for: directoryTargets, generation: generation)
        }

        await drainPendingAddEntries(generation: generation)
    }

    /// Add local URLs in compress mode without blocking the main actor.
    /// Rapid sequential drops are queued onto the active load worker rather than cancelling prior drops.
    /// In `.browseArchive` mode, additions must go through `CompressionCoordinator.addEntries`.
    public func addEntries(from urls: [URL]) {
        guard mode == .compress, !urls.isEmpty else { return }
        pendingAddedURLs.append(contentsOf: urls)
        startAddEntriesWorkerIfNeeded(generation: loadGeneration)
    }

    /// Async variant of `addEntries(from:)` that awaits queued additions and their folder size calculations.
    public func addEntriesAsync(from urls: [URL]) async {
        guard mode == .compress, !urls.isEmpty else { return }
        let generation = loadGeneration
        pendingAddedURLs.append(contentsOf: urls)
        startAddEntriesWorkerIfNeeded(generation: generation)
        await waitForPendingWork(generation: generation)
    }

    private func startAddEntriesWorkerIfNeeded(generation: UInt64) {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.runAddEntriesWorker(generation: generation)
        }
    }

    private func runAddEntriesWorker(generation: UInt64) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        defer {
            if loadGeneration == generation {
                loadTask = nil
                updateLoadingStateIfIdle(generation: generation)
            }
        }
        await drainPendingAddEntries(generation: generation)
    }

    private func drainPendingAddEntries(generation: UInt64) async {
        while !pendingAddedURLs.isEmpty {
            guard !Task.isCancelled, loadGeneration == generation, mode == .compress else {
                if loadGeneration == generation {
                    pendingAddedURLs.removeAll()
                }
                return
            }

            let batch = pendingAddedURLs
            pendingAddedURLs.removeAll(keepingCapacity: true)

            var seenPaths = Set(rootNodes.map { $0.url.standardizedFileURL.path })
            var newURLs: [URL] = []
            newURLs.reserveCapacity(batch.count)
            for url in batch {
                let standardizedPath = url.standardizedFileURL.path
                if seenPaths.insert(standardizedPath).inserted {
                    newURLs.append(url)
                }
            }
            guard !newURLs.isEmpty else { continue }

            let shallowAdditions = await FileUtils.buildShallowEntriesAsync(from: newURLs)
            guard !Task.isCancelled, loadGeneration == generation, mode == .compress else { return }

            let currentPaths = Set(rootNodes.map { $0.url.standardizedFileURL.path })
            let uniqueAdditions = shallowAdditions.filter {
                !currentPaths.contains($0.url.standardizedFileURL.path)
            }
            guard !uniqueAdditions.isEmpty else { continue }

            let addedNodes = uniqueAdditions.map { FileNode(entry: $0) }
            let directoryTargets = addedNodes.filter(\.isDirectory).map { ($0.id, $0.url) }
            appendRootNodes(addedNodes)
            if !directoryTargets.isEmpty {
                enqueueSizeCalculation(for: directoryTargets, generation: generation)
            }
        }
    }

    private func waitForPendingWork(generation: UInt64) async {
        while loadGeneration == generation {
            if let activeLoad = loadTask {
                await activeLoad.value
            } else if let activeSizing = sizeCalculationTask {
                await activeSizing.value
            } else {
                break
            }
        }
    }

    // MARK: - Lazy Directory Expansion

    /// Lazily load immediate (1-level) children of a local directory off the main actor.
    public func loadChildrenIfNeeded(for node: FileNode) {
        guard node.isDirectory,
              !node.isFromArchive,
              !node.hasLoadedChildren,
              loadingChildTasks[node.id] == nil else {
            return
        }
        let nodeID = node.id
        let directoryURL = node.url
        let generation = loadGeneration
        loadingChildTasks[nodeID] = Task { [weak self] in
            await self?.performLoadChildren(nodeID: nodeID, directoryURL: directoryURL, generation: generation)
        }
    }

    /// Async variant of `loadChildrenIfNeeded(for:)` suitable for awaiting completion in callers and tests.
    public func loadChildrenIfNeededAsync(for node: FileNode) async {
        guard node.isDirectory,
              !node.isFromArchive,
              !node.hasLoadedChildren else {
            return
        }
        if let existingTask = loadingChildTasks[node.id] {
            await existingTask.value
            return
        }
        let nodeID = node.id
        let directoryURL = node.url
        let generation = loadGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.performLoadChildren(nodeID: nodeID, directoryURL: directoryURL, generation: generation)
        }
        loadingChildTasks[nodeID] = task
        await task.value
    }

    /// Compatibility overload forwarding `FileEntry` lookups to the live `FileNode`.
    public func loadChildrenIfNeeded(for entry: FileEntry) {
        guard let liveNode = node(for: entry.id) else { return }
        loadChildrenIfNeeded(for: liveNode)
    }

    private func performLoadChildren(nodeID: UUID, directoryURL: URL, generation: UInt64) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        let childEntries = await FileUtils.loadImmediateChildrenAsync(of: directoryURL)
        if loadGeneration == generation {
            loadingChildTasks.removeValue(forKey: nodeID)
        }
        guard !Task.isCancelled,
              loadGeneration == generation,
              mode == .compress,
              let liveNode = node(for: nodeID),
              !liveNode.hasLoadedChildren else {
            return
        }
        let filteredEntries = excludedCompressStandardizedPaths.isEmpty
            ? childEntries
            : childEntries.filter { !excludedCompressStandardizedPaths.contains($0.url.standardizedFileURL.path) }
        let childNodes = filteredEntries.map { FileNode(entry: $0, parent: liveNode) }
        attachLoadedChildren(childNodes, to: nodeID)
    }

    // MARK: - Background Folder Sizing

    private func enqueueSizeCalculation(for targets: [(id: UUID, url: URL)], generation: UInt64) {
        guard !targets.isEmpty, loadGeneration == generation else { return }
        pendingSizeTargets.append(contentsOf: targets)
        isCalculatingSizes = true
        guard sizeCalculationTask == nil else { return }

        sizeCalculationTask = Task { [weak self] in
            await self?.drainSizeCalculationQueue(generation: generation)
        }
    }

    private func drainSizeCalculationQueue(generation: UInt64) async {
        guard !Task.isCancelled, loadGeneration == generation else { return }
        defer {
            if loadGeneration == generation {
                sizeCalculationTask = nil
                if Task.isCancelled {
                    pendingSizeTargets.removeAll()
                }
                updateLoadingStateIfIdle(generation: generation)
            }
        }

        while !pendingSizeTargets.isEmpty {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let (nodeID, url) = pendingSizeTargets.removeFirst()
            guard node(for: nodeID) != nil else { continue }
            let excluded = excludedCompressStandardizedPaths
            guard let bytes = await FileUtils.computeDirectorySizeAsync(
                at: url,
                excludingStandardizedPaths: excluded
            ) else {
                if Task.isCancelled || loadGeneration != generation {
                    return
                }
                continue
            }
            guard !Task.isCancelled, loadGeneration == generation else { return }
            updateNodeSize(id: nodeID, bytes: bytes)
        }
    }

    // MARK: - Navigation, Selection & Local Removal

    public func loadArchive(from url: URL) {
        mode = .browseArchive
        sourceArchiveURL = url
    }

    /// Navigate into `node` immediately without blocking the main actor; unexpanded local folders
    /// populate their immediate children asynchronously.
    public func navigateInto(_ node: FileNode) {
        let target = resolveOrRegisterNode(node)
        guard target.isDirectory else { return }
        pushNavigationNode(id: target.id)
        if !target.isFromArchive && !target.hasLoadedChildren {
            loadChildrenIfNeeded(for: target)
        }
    }

    public func navigateInto(_ entry: FileEntry) {
        navigateInto(node(for: entry.id) ?? FileNode(entry: entry))
    }

    /// Async variant of `navigateInto(_:)` that pushes navigation immediately and awaits child loading
    /// for unexpanded local folders.
    public func navigateIntoAsync(_ node: FileNode) async {
        let target = resolveOrRegisterNode(node)
        guard target.isDirectory else { return }
        pushNavigationNode(id: target.id)
        if !target.isFromArchive && !target.hasLoadedChildren {
            await loadChildrenIfNeededAsync(for: target)
        }
    }

    public func navigateIntoAsync(_ entry: FileEntry) async {
        await navigateIntoAsync(node(for: entry.id) ?? FileNode(entry: entry))
    }

    public func navigateUp() { popNavigationNode() }

    public func navigateBack(to level: Int = 0) { truncateNavigation(to: level) }

    public func selectAll() {
        selectedEntryIDs = Set(displayedNodes.map(\.id))
    }

    public func clearSelection() {
        selectedEntryIDs.removeAll()
    }

    public func removeEntries(at offsets: IndexSet) {
        guard mode != .browseArchive else { return }
        let ids = Set(offsets.compactMap { rootNodes.indices.contains($0) ? rootNodes[$0].id : nil })
        let resizeTargets = removeNodesInTree(matching: ids)
        if !resizeTargets.isEmpty {
            enqueueSizeCalculation(for: resizeTargets, generation: loadGeneration)
        }
    }

    public func removeSelectedEntries() {
        guard mode != .browseArchive else { return }
        let ids = selectedEntryIDs
        let resizeTargets = removeNodesInTree(matching: ids)
        selectedEntryIDs.removeAll()
        if !resizeTargets.isEmpty {
            enqueueSizeCalculation(for: resizeTargets, generation: loadGeneration)
        }
    }

    public func removeNodes(_ nodes: [FileNode]) {
        guard mode != .browseArchive, !nodes.isEmpty else { return }
        let resizeTargets = removeNodesInTree(matching: Set(nodes.map(\.id)))
        if !resizeTargets.isEmpty {
            enqueueSizeCalculation(for: resizeTargets, generation: loadGeneration)
        }
    }

    // MARK: - Drop Routing

    /// Return the URL if `urls` represents dropping or opening a single archive file; otherwise `nil`.
    public nonisolated static func isArchiveDrop(_ urls: [URL]) -> URL? {
        guard urls.count == 1, let first = urls.first, FormatDetector.isArchiveFile(first) else {
            return nil
        }
        return first
    }

    /// Route dropped or opened URLs to archive browsing or compression staging.
    public func handleDroppedURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let archiveURL = await Task.detached(priority: .userInitiated) {
            Self.isArchiveDrop(urls)
        }.value

        if let archiveURL {
            await coordinator.browseArchive(at: archiveURL, appState: self)
        } else {
            await loadFilesAsync(from: urls)
        }
    }
}
