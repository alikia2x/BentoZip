import Foundation

extension AppState {

    // MARK: - Loading & Staging Local Files

    /// Load local files or directories into compress mode without blocking the main actor.
    /// Top-level items appear immediately; folder contents load lazily on expansion, and folder
    /// byte sizes stream in on a low-priority background task without allocating child entry trees.
    public func loadFiles(from urls: [URL]) {
        loadTask?.cancel()
        sizeCalculationTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.performLoadFiles(from: urls)
        }
    }

    /// Async variant of `loadFiles(from:)` suitable for awaiting completion in callers and tests.
    public func loadFilesAsync(from urls: [URL]) async {
        loadTask?.cancel()
        loadTask = nil
        sizeCalculationTask?.cancel()
        sizeCalculationTask = nil
        await performLoadFiles(from: urls)
    }

    private func performLoadFiles(from urls: [URL]) async {
        navigationPath = []
        selectedEntryIDs = []
        loadingChildIDs.removeAll()
        lastError = nil
        sourceArchiveURL = nil
        archivePackedSize = nil
        archivePassword = nil
        cancelPasswordPrompt()

        let shallowEntries = await FileUtils.buildShallowEntriesAsync(from: urls)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        let directoryTargets = shallowEntries.filter(\.isDirectory).map { ($0.id, $0.url) }
        fileEntries = shallowEntries
        mode = .compress
        showInspector = true
        isLoading = !directoryTargets.isEmpty

        guard !directoryTargets.isEmpty else { return }

        await computeFolderSizes(for: directoryTargets)
    }

    /// Add local URLs in compress mode without blocking the main actor.
    /// In `.browseArchive` mode, additions must go through `CompressionCoordinator.addEntries`.
    public func addEntries(from urls: [URL]) {
        guard mode == .compress else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.performAddEntries(from: urls)
        }
    }

    public func addEntriesAsync(from urls: [URL]) async {
        loadTask?.cancel()
        loadTask = nil
        await performAddEntries(from: urls)
    }

    private func performAddEntries(from urls: [URL]) async {
        guard mode == .compress, !urls.isEmpty else { return }
        let existingPaths = Set(fileEntries.map { $0.url.standardizedFileURL.path })
        let newURLs = urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }
        guard !newURLs.isEmpty else { return }

        let shallowAdditions = await FileUtils.buildShallowEntriesAsync(from: newURLs)
        guard !Task.isCancelled else { return }

        let directoryTargets = shallowAdditions.filter(\.isDirectory).map { ($0.id, $0.url) }
        fileEntries = Self.sortedEntries(fileEntries + shallowAdditions)
        guard !directoryTargets.isEmpty else { return }

        isLoading = true
        await computeFolderSizes(for: directoryTargets)
    }

    /// Lazily load immediate (1-level) children of a local directory when expanded in the outline view.
    public func loadChildrenIfNeeded(for entry: FileEntry) {
        guard entry.isDirectory,
              !entry.isFromArchive,
              !entry.hasLoadedChildren,
              !loadingChildIDs.contains(entry.id) else {
            return
        }

        let entryID = entry.id
        let directoryURL = entry.url
        loadingChildIDs.insert(entryID)

        Task { [weak self] in
            let children = await FileUtils.loadImmediateChildrenAsync(of: directoryURL)
            guard let self else { return }
            self.loadingChildIDs.remove(entryID)
            guard self.mode == .compress else { return }
            self.updateEntry(id: entryID) { node in
                node.children = children
                node.hasLoadedChildren = true
            }
        }
    }

    // MARK: - Background Folder Sizing

    private func computeFolderSizes(for targets: [(id: UUID, url: URL)]) async {
        let task = Task { [weak self] in
            guard let self else { return }
            for (entryID, url) in targets {
                if Task.isCancelled { break }
                guard let bytes = await FileUtils.computeDirectorySizeAsync(at: url) else {
                    break
                }
                if Task.isCancelled { break }
                self.updateEntry(id: entryID) { node in
                    node.size = bytes
                }
            }
            if !Task.isCancelled {
                self.isLoading = false
            }
        }
        sizeCalculationTask = task
        await task.value
    }

    // MARK: - In-Place Tree Mutation (Preserves Stable Entry IDs)

    func updateEntry(id: UUID, mutate: (inout FileEntry) -> Void) {
        var updated = fileEntries
        if Self.mutateEntry(id: id, in: &updated, mutate: mutate) {
            fileEntries = updated
        }
        for i in navigationPath.indices {
            if navigationPath[i].id == id {
                mutate(&navigationPath[i])
            } else if var children = navigationPath[i].children,
                      Self.mutateEntry(id: id, in: &children, mutate: mutate) {
                navigationPath[i].children = children
            }
        }
    }

    private static func mutateEntry(
        id: UUID,
        in entries: inout [FileEntry],
        mutate: (inout FileEntry) -> Void
    ) -> Bool {
        for i in entries.indices {
            if entries[i].id == id {
                mutate(&entries[i])
                return true
            }
            if var children = entries[i].children,
               mutateEntry(id: id, in: &children, mutate: mutate) {
                entries[i].children = children
                return true
            }
        }
        return false
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

    // MARK: - Entry Metrics & Tree Lookup

    func recomputeEntryMetrics() {
        var totalBytes: Int64 = 0
        var totalPacked: Int64 = 0
        var hasPacked = false
        var count = 0
        var encrypted = false

        func walkArchive(_ entries: [FileEntry]) {
            for entry in entries {
                count += 1
                if entry.isEncrypted {
                    encrypted = true
                }
                if entry.isDirectory, let children = entry.children {
                    walkArchive(children)
                } else {
                    totalBytes += entry.size
                    if let packed = entry.packedSize {
                        hasPacked = true
                        totalPacked += packed
                    }
                }
            }
        }

        if fileEntries.first?.isFromArchive == true {
            walkArchive(fileEntries)
        } else {
            for entry in fileEntries {
                count += 1
                totalBytes += entry.size
            }
        }

        totalSize = totalBytes
        cachedEntryPackedSize = hasPacked ? totalPacked : nil
        totalEntryCount = count
        cachedContainsEncryptedEntry = encrypted
    }

    static func collectMatchingEntries(ids: Set<UUID>, in entries: [FileEntry]) -> [FileEntry] {
        guard !ids.isEmpty else { return [] }
        var result: [FileEntry] = []
        for entry in entries {
            if ids.contains(entry.id) {
                result.append(entry)
            }
            if let children = entry.children, !children.isEmpty {
                result.append(contentsOf: collectMatchingEntries(ids: ids, in: children))
            }
        }
        return result
    }

    static func sortedEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
