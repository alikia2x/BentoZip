import Foundation

extension AppState {

    // MARK: - Loading & Staging Local Files

    /// Load local files or directories into compress mode without blocking the main actor.
    public func loadFiles(from urls: [URL]) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.performLoadFiles(from: urls)
        }
    }

    /// Async variant of `loadFiles(from:)` suitable for awaiting completion in callers and tests.
    public func loadFilesAsync(from urls: [URL]) async {
        loadTask?.cancel()
        loadTask = nil
        await performLoadFiles(from: urls)
    }

    private func performLoadFiles(from urls: [URL]) async {
        navigationPath = []
        selectedEntryIDs = []
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

        let hasDirectories = shallowEntries.contains(where: \.isDirectory)
        fileEntries = shallowEntries
        mode = .compress
        showInspector = true
        isLoading = hasDirectories

        guard hasDirectories else { return }

        let scannedEntries = await FileUtils.buildFileEntries(from: urls)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        fileEntries = scannedEntries
        isLoading = false
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

        isLoading = true
        let shallowAdditions = await FileUtils.buildShallowEntriesAsync(from: newURLs)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        let hasDirectories = shallowAdditions.contains(where: \.isDirectory)
        fileEntries = Self.sortedEntries(fileEntries + shallowAdditions)
        guard hasDirectories else {
            isLoading = false
            return
        }

        let scannedAdditions = await FileUtils.buildFileEntries(from: newURLs)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        let additionPaths = Set(newURLs.map { $0.standardizedFileURL.path })
        let preserved = fileEntries.filter { !additionPaths.contains($0.url.standardizedFileURL.path) }
        fileEntries = Self.sortedEntries(preserved + scannedAdditions)
        isLoading = false
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

    // MARK: - Entry Metrics & Sorting

    func recomputeEntryMetrics() {
        var totalBytes: Int64 = 0
        var totalPacked: Int64 = 0
        var hasPacked = false
        var count = 0
        var encrypted = false

        func walk(_ entries: [FileEntry]) {
            for entry in entries {
                count += 1
                if entry.isEncrypted {
                    encrypted = true
                }
                if entry.isDirectory, let children = entry.children {
                    walk(children)
                } else {
                    totalBytes += entry.size
                    if let packed = entry.packedSize {
                        hasPacked = true
                        totalPacked += packed
                    }
                }
            }
        }

        walk(fileEntries)
        totalSize = totalBytes
        cachedEntryPackedSize = hasPacked ? totalPacked : nil
        totalEntryCount = count
        cachedContainsEncryptedEntry = encrypted
    }

    static func sortedEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
