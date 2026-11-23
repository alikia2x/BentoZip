import SwiftUI
import Observation

/// Owns a `NotificationCenter` observer token and unregisters it automatically on deallocation.
private final class NotificationObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(name: Notification.Name, queue: OperationQueue?, block: @escaping @Sendable (Notification) -> Void) {
        self.token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue, using: block)
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Represents an operation interrupted by a password prompt so it can be retried once unlocked.
public enum PendingPasswordAction: Sendable, Equatable {
    case browse(URL)
    case extract(URL, entries: [FileEntry]?, chooseDestination: Bool)
}

@Observable
@MainActor
public class AppState {
    public var mode: ArchiveMode = .empty

    public var fileEntries: [FileEntry] = []

    public var navigationPath: [FileEntry] = []

    public var selectedEntryIDs: Set<UUID> = []

    public var isLoading: Bool = false

    public var displayedEntries: [FileEntry] {
        if let last = navigationPath.last {
            return last.children ?? []
        }
        return fileEntries
    }

    public var selectedEntries: [FileEntry] {
        displayedEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    public var canNavigateUp: Bool {
        !navigationPath.isEmpty
    }

    public var totalSize: Int64 {
        Self.sumSize(of: fileEntries, packed: false)
    }

    /// Archive-level packed size reported by the backend (accurate for solid 7z and compound tar streams).
    public var archivePackedSize: Int64?

    public var totalPackedSize: Int64? {
        if let archivePackedSize, archivePackedSize > 0 {
            return archivePackedSize
        }
        guard Self.hasPackedSize(in: fileEntries) else { return nil }
        return Self.sumSize(of: fileEntries, packed: true)
    }

    public var totalEntryCount: Int {
        Self.countEntries(in: fileEntries)
    }

    public var isArchiveEncrypted: Bool {
        archivePassword != nil || Self.containsEncryptedEntry(in: fileEntries)
    }

    public var archiveFormatName: String? {
        guard let url = sourceArchiveURL else { return nil }
        return FormatDetector.detectReadableFormat(of: url)?.displayName
    }

    public var isWritableArchive: Bool {
        guard mode == .browseArchive, let archiveURL = sourceArchiveURL else {
            return false
        }
        return FormatDetector.detectFormat(of: archiveURL) != nil
    }

    public var isReadOnlyArchive: Bool {
        guard mode == .browseArchive, let archiveURL = sourceArchiveURL else {
            return false
        }
        return FormatDetector.detectReadableFormat(of: archiveURL)?.isReadOnly == true
    }

    public var suggestedArchiveName: String {
        let ext = compressionSettings.format.fileExtension
        if fileEntries.count == 1, let first = fileEntries.first {
            let stem = first.isDirectory
                ? first.url.lastPathComponent
                : first.url.deletingPathExtension().lastPathComponent
            let safeStem = stem.isEmpty ? "archive" : stem
            return "\(safeStem).\(ext)"
        }
        return "archive.\(ext)"
    }

    public var compressionSettings = CompressionSettings()

    public var showInspector: Bool = false

    public var sourceArchiveURL: URL?

    public var lastError: String?

    // Password flow state
    public var archivePassword: String?
    public var needsPasswordPrompt: Bool = false
    public var passwordPromptReason: String?
    public var isPasswordRetryError: Bool = false
    public var pendingPasswordArchiveURL: URL?
    public var pendingPasswordAction: PendingPasswordAction?

    // Validated recent archives (populated asynchronously off the main actor)
    public private(set) var recentArchiveURLs: [URL] = []

    // User preferences synced with PreferencesManager when available
    public var revealInFinderAfterExtract: Bool = true
    public var unwrapSingleTopDirectory: Bool = true

    public var coordinator = CompressionCoordinator()
    public var preferencesManager: PreferencesManager? {
        didSet {
            applyPreferences()
            refreshRecentArchives()
        }
    }

    private var loadTask: Task<Void, Never>?
    private var recentValidationTask: Task<Void, Never>?
    private var preferencesObserver: NotificationObserverToken?

    public init() {
        preferencesObserver = NotificationObserverToken(
            name: PreferencesManager.preferencesDidChangeNotification,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handlePreferencesDidChange()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handlePreferencesDidChange()
                }
            }
        }
    }

    public func applyPreferences() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
    }

    /// Persist current compression settings and behavior toggles to `AppPreferences`.
    public func savePreferences() {
        preferencesManager?.updatePreferences { prefs in
            prefs.defaultFormat = compressionSettings.format.rawValue
            prefs.defaultCompressionLevel = compressionSettings.compressionLevel.rawValue
            prefs.exclusionPatterns = compressionSettings.exclusionPatterns
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
        }
    }

    /// Load local files or directories into compress mode without blocking the main actor.
    public func loadFiles(from urls: [URL]) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadFilesAsync(from: urls)
        }
    }

    /// Async variant of `loadFiles(from:)` suitable for awaiting completion in callers and tests.
    public func loadFilesAsync(from urls: [URL]) async {
        loadTask?.cancel()
        navigationPath = []
        selectedEntryIDs = []
        lastError = nil
        sourceArchiveURL = nil
        archivePackedSize = nil
        archivePassword = nil
        needsPasswordPrompt = false
        passwordPromptReason = nil
        isPasswordRetryError = false
        pendingPasswordArchiveURL = nil
        pendingPasswordAction = nil

        fileEntries = FileUtils.buildShallowEntries(from: urls)
        mode = .compress
        showInspector = true
        isLoading = true

        let scannedEntries = await FileUtils.buildFileEntries(from: urls)
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        fileEntries = scannedEntries
        isLoading = false
    }

    public func loadArchive(from url: URL) {
        mode = .browseArchive
        sourceArchiveURL = url
    }

    public func navigateInto(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        navigationPath.append(entry)
        selectedEntryIDs.removeAll()
    }

    public func navigateUp() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        selectedEntryIDs.removeAll()
    }

    public func navigateBack(to level: Int = 0) {
        if level <= 0 {
            navigationPath.removeAll()
        } else {
            let safeLevel = min(level, navigationPath.count)
            navigationPath.removeLast(navigationPath.count - safeLevel)
        }
        selectedEntryIDs.removeAll()
    }

    public func selectAll() {
        selectedEntryIDs = Set(displayedEntries.map(\.id))
    }

    public func clearSelection() {
        selectedEntryIDs.removeAll()
    }

    public func removeEntries(at offsets: IndexSet) {
        if mode == .browseArchive {
            return
        }
        fileEntries.remove(atOffsets: offsets)
    }

    public func removeSelectedEntries() {
        if mode == .browseArchive {
            return
        }
        fileEntries.removeAll { selectedEntryIDs.contains($0.id) }
        selectedEntryIDs.removeAll()
    }

    /// Add local URLs in compress mode without blocking the main actor.
    /// In `.browseArchive` mode, additions must go through `CompressionCoordinator.addEntries`.
    public func addEntries(from urls: [URL]) {
        guard mode == .compress else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.addEntriesAsync(from: urls)
        }
    }

    public func addEntriesAsync(from urls: [URL]) async {
        guard mode == .compress, !urls.isEmpty else { return }
        let existingPaths = Set(fileEntries.map { $0.url.standardizedFileURL.path })
        let newURLs = urls.filter { !existingPaths.contains($0.standardizedFileURL.path) }
        guard !newURLs.isEmpty else { return }

        isLoading = true
        let shallowAdditions = FileUtils.buildShallowEntries(from: newURLs)
        fileEntries = Self.sortedEntries(fileEntries + shallowAdditions)

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

    public func reset() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        mode = .empty
        fileEntries = []
        navigationPath = []
        selectedEntryIDs = []
        compressionSettings = CompressionSettings()
        showInspector = false
        sourceArchiveURL = nil
        archivePackedSize = nil
        lastError = nil
        archivePassword = nil
        needsPasswordPrompt = false
        passwordPromptReason = nil
        isPasswordRetryError = false
        pendingPasswordArchiveURL = nil
        pendingPasswordAction = nil
        DragDropManager.shared.cleanup()
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
        guard urls.count == 1, let first = urls.first else {
            return "archive"
        }
        if FileUtils.isDirectory(at: first) {
            return first.lastPathComponent
        }
        let stem = first.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? first.lastPathComponent : stem
    }

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

    /// Revalidate `recentArchives` asynchronously off the main actor.
    public func refreshRecentArchives() {
        recentValidationTask?.cancel()
        guard let manager = preferencesManager else {
            recentArchiveURLs = []
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
            recentArchiveURLs = []
            return
        }
        let rawPaths = manager.loadPreferences().recentArchives
        await validateAndSetRecentArchives(rawPaths)
    }

    private func validateAndSetRecentArchives(_ rawPaths: [String]) async {
        let validated = await Task.detached(priority: .utility) {
            var urls: [URL] = []
            urls.reserveCapacity(rawPaths.count)
            for path in rawPaths {
                if Task.isCancelled { return urls }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path),
                   FormatDetector.isArchiveFile(url) {
                    urls.append(url)
                }
            }
            return urls
        }.value
        guard !Task.isCancelled else { return }
        recentArchiveURLs = validated
    }

    private func handlePreferencesDidChange() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        if mode == .empty {
            preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        }
        refreshRecentArchives()
    }

    // MARK: - Helpers

    private static func countEntries(in entries: [FileEntry]) -> Int {
        entries.reduce(0) { count, entry in
            if let children = entry.children {
                return count + 1 + countEntries(in: children)
            }
            return count + 1
        }
    }

    private static func sortedEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func sumSize(of entries: [FileEntry], packed: Bool) -> Int64 {
        entries.reduce(0) { total, entry in
            if entry.isDirectory, let children = entry.children {
                return total + sumSize(of: children, packed: packed)
            }
            if packed {
                return total + (entry.packedSize ?? 0)
            } else {
                return total + entry.size
            }
        }
    }

    private static func hasPackedSize(in entries: [FileEntry]) -> Bool {
        for entry in entries {
            if entry.packedSize != nil {
                return true
            }
            if let children = entry.children, hasPackedSize(in: children) {
                return true
            }
        }
        return false
    }

    private static func containsEncryptedEntry(in entries: [FileEntry]) -> Bool {
        for entry in entries {
            if entry.isEncrypted {
                return true
            }
            if let children = entry.children, containsEncryptedEntry(in: children) {
                return true
            }
        }
        return false
    }
}
