import Foundation

/// Lightweight validated recent archive metadata loaded off the main actor.
public struct RecentArchiveItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let fileSize: Int64?

    public init(url: URL, fileSize: Int64? = nil) {
        self.url = url
        self.fileSize = fileSize
    }
}

/// Represents an operation interrupted by a password prompt so it can be retried once unlocked.
public enum PendingPasswordAction: Sendable, Equatable {
    case browse(URL)
    case extract(URL, entries: [FileEntry]?, chooseDestination: Bool)
    case preview([FileEntry])
    case openFile(FileEntry, appURL: URL?)
}

extension AppState {

    // MARK: - Archive Metadata & Reset

    public var totalPackedSize: Int64? {
        if let archivePackedSize, archivePackedSize > 0 { return archivePackedSize }
        return cachedEntryPackedSize
    }

    public var isArchiveEncrypted: Bool { archivePassword != nil || cachedContainsEncryptedEntry }

    public var archiveFormatName: String? {
        guard let url = sourceArchiveURL else { return nil }
        return FormatDetector.detectReadableFormat(of: url)?.displayName
    }

    public var isWritableArchive: Bool {
        guard mode == .browseArchive, let archiveURL = sourceArchiveURL else { return false }
        return FormatDetector.detectFormat(of: archiveURL) != nil
    }

    public var isReadOnlyArchive: Bool {
        guard mode == .browseArchive, let archiveURL = sourceArchiveURL else { return false }
        return FormatDetector.detectReadableFormat(of: archiveURL)?.isReadOnly == true
    }

    public var suggestedArchiveName: String {
        let ext = compressionSettings.format.fileExtension
        if rootNodes.count == 1, let first = rootNodes.first {
            let stem = first.isDirectory ? first.url.lastPathComponent : first.url.deletingPathExtension().lastPathComponent
            return "\(stem.isEmpty ? "archive" : stem).\(ext)"
        }
        return "archive.\(ext)"
    }

    public var recentArchiveURLs: [URL] { recentArchiveItems.map(\.url) }

    public func reset() {
        cancelBackgroundTasks()
        activeConflictPrompt?.cancel()
        activeConflictPrompt = nil
        unwrappedRootPath = nil
        testArchiveResult = nil
        searchQuery = ""
        isSearchVisible = false
        selectedEncoding = .auto
        mode = .empty
        clearNavigationAndSelection()
        replaceRootNodes([])
        compressionSettings = CompressionSettings()
        showInspector = false
        sourceArchiveURL = nil
        archivePackedSize = nil
        lastError = nil
        archivePassword = nil
        cancelPasswordPrompt()
        applyPreferences()
    }

    /// Clear active password prompt state when dismissed/cancelled by the user.
    public func cancelPasswordPrompt() {
        needsPasswordPrompt = false
        passwordPromptReason = nil
        isPasswordRetryError = false
        pendingPasswordArchiveURL = nil
        pendingPasswordAction = nil
    }

    // MARK: - Preferences

    public func applyPreferences() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        extractConflictPolicy = ExtractConflictPolicy(rawValue: prefs.extractConflictPolicy) ?? .ask
        moveArchiveToTrashAfterExtract = prefs.moveArchiveToTrashAfterExtract
        closeWindowAfterExtract = prefs.closeWindowAfterExtract
        showHiddenFiles = prefs.showHiddenFiles
    }

    /// Persist current compression settings and behavior toggles to `AppPreferences`.
    public func savePreferences() {
        preferencesManager?.updatePreferences { prefs in
            prefs.defaultFormat = compressionSettings.format.rawValue
            prefs.defaultCompressionLevel = compressionSettings.compressionLevel.rawValue
            prefs.exclusionPatterns = compressionSettings.exclusionPatterns
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
            prefs.extractConflictPolicy = extractConflictPolicy.rawValue
            prefs.moveArchiveToTrashAfterExtract = moveArchiveToTrashAfterExtract
            prefs.closeWindowAfterExtract = closeWindowAfterExtract
            prefs.showHiddenFiles = showHiddenFiles
        }
    }

    func handlePreferencesDidChange() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        extractConflictPolicy = ExtractConflictPolicy(rawValue: prefs.extractConflictPolicy) ?? .ask
        moveArchiveToTrashAfterExtract = prefs.moveArchiveToTrashAfterExtract
        closeWindowAfterExtract = prefs.closeWindowAfterExtract
        showHiddenFiles = prefs.showHiddenFiles
        if mode == .empty {
            preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        }
        refreshRecentArchives()
    }

    // MARK: - Recent Archives

    /// Revalidate `recentArchives` asynchronously off the main actor.
    public func refreshRecentArchives() {
        recentValidationTask?.cancel()
        guard let manager = preferencesManager else {
            recentArchiveItems = []
            return
        }
        let rawPaths = manager.loadPreferences().recentArchives
        recentValidationTask = Task { [weak self] in
            await self?.validateAndSetRecentArchives(rawPaths)
        }
    }

    /// Async variant of `refreshRecentArchives()` suitable for awaiting in tests.
    public func refreshRecentArchivesAsync() async {
        recentValidationTask?.cancel()
        guard let manager = preferencesManager else {
            recentArchiveItems = []
            return
        }
        let rawPaths = manager.loadPreferences().recentArchives
        await validateAndSetRecentArchives(rawPaths)
    }

    private func validateAndSetRecentArchives(_ rawPaths: [String]) async {
        guard !Task.isCancelled else { return }
        let validated = await Task.detached(priority: .utility) {
            var items: [RecentArchiveItem] = []
            items.reserveCapacity(rawPaths.count)
            for path in rawPaths {
                if Task.isCancelled { return items }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path),
                   FormatDetector.isArchiveFile(url) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                    let size = values?.fileSize.map(Int64.init)
                    items.append(RecentArchiveItem(url: url, fileSize: size))
                }
            }
            return items
        }.value
        guard !Task.isCancelled else { return }
        recentArchiveItems = validated
    }

    // MARK: - Archive Naming Helpers

    /// Return the archive name with its extension synchronized from `oldFormat` to `newFormat`.
    public func archiveNameWithSyncedExtension(oldFormat: ArchiveFormat, newFormat: ArchiveFormat) -> String {
        CompressionSettings.archiveNameWithSyncedExtension(
            compressionSettings.archiveName,
            oldFormat: oldFormat,
            newFormat: newFormat
        )
    }

    /// Switch `compressionSettings.format` and synchronize `compressionSettings.archiveName` extension.
    public func updateCompressionFormat(to newFormat: ArchiveFormat) {
        compressionSettings = compressionSettings.updatingFormat(to: newFormat)
    }

    /// Compute default archive filename stem (without extension) for local URLs.
    /// Directories preserve dots in their name (e.g. `Project.v1.0`).
    public nonisolated static func defaultArchiveStem(for urls: [URL]) -> String {
        guard urls.count == 1, let first = urls.first else { return "archive" }
        if FileUtils.isDirectory(at: first) { return first.lastPathComponent }
        let stem = first.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? first.lastPathComponent : stem
    }

    // MARK: - Entry Metrics & Sorting

    func recomputeEntryMetrics() {
        var totalBytes: Int64 = 0
        var totalPacked: Int64 = 0
        var hasPacked = false
        var count = 0
        var encrypted = false

        func walkArchive(_ nodes: [FileNode]) {
            for node in nodes {
                count += 1
                if node.isEncrypted { encrypted = true }
                if node.isDirectory, let children = node.children {
                    walkArchive(children)
                } else {
                    totalBytes += node.size
                    if let packed = node.packedSize {
                        hasPacked = true
                        totalPacked += packed
                    }
                }
            }
        }

        if rootNodes.first?.isFromArchive == true {
            walkArchive(rootNodes)
        } else {
            for node in rootNodes {
                count += 1
                totalBytes += node.size
            }
        }

        totalSize = totalBytes
        cachedEntryPackedSize = hasPacked ? totalPacked : nil
        totalEntryCount = count
        cachedContainsEncryptedEntry = encrypted
    }

    static func sortedNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
