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
}

@Observable
@MainActor
public class AppState {
    public var mode: ArchiveMode = .empty
    public var fileEntries: [FileEntry] = [] {
        didSet { recomputeEntryMetrics() }
    }
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

    public var canNavigateUp: Bool { !navigationPath.isEmpty }

    public internal(set) var totalSize: Int64 = 0
    /// Archive-level packed size reported by the backend (accurate for solid 7z and compound tar streams).
    public var archivePackedSize: Int64?
    var cachedEntryPackedSize: Int64?
    var cachedContainsEncryptedEntry: Bool = false

    public var totalPackedSize: Int64? {
        if let archivePackedSize, archivePackedSize > 0 {
            return archivePackedSize
        }
        return cachedEntryPackedSize
    }

    public internal(set) var totalEntryCount: Int = 0

    public var isArchiveEncrypted: Bool {
        archivePassword != nil || cachedContainsEncryptedEntry
    }

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
    public internal(set) var recentArchiveItems: [RecentArchiveItem] = []

    public var recentArchiveURLs: [URL] {
        recentArchiveItems.map(\.url)
    }

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

    var loadTask: Task<Void, Never>?
    var recentValidationTask: Task<Void, Never>?
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

    // MARK: - Navigation & Selection

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
        if mode == .browseArchive { return }
        fileEntries.remove(atOffsets: offsets)
    }

    public func removeSelectedEntries() {
        if mode == .browseArchive { return }
        fileEntries.removeAll { selectedEntryIDs.contains($0.id) }
        selectedEntryIDs.removeAll()
    }

    // MARK: - Reset & Password Prompt

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
        cancelPasswordPrompt()
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
}
