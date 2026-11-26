import AppKit
import BentoZipCore
import Security
import SwiftUI
import UniformTypeIdentifiers

/// Launch payload passed to `WindowGroup(id: "workspace", for: WorkspaceLaunchRequest.self)`.
enum WorkspaceLaunchRequest: Codable, Hashable {
    case empty
    case openArchive(URL)
    case compressFiles([URL])
}

/// Central document-window coordinator enabling genuine macOS multi-window Document-Based App behavior
/// while keeping the Welcome window on cold launch.
@MainActor
final class DocumentWindowRouter {
    static let shared = DocumentWindowRouter()

    private struct WindowRecord {
        let id: ObjectIdentifier
        weak var window: NSWindow?
        weak var appState: AppState?
        weak var progressState: ProgressState?
        weak var uiState: WorkspaceUIState?
        var representedArchivePath: String?
    }

    private var records: [ObjectIdentifier: WindowRecord] = [:]
    private var openingArchivePaths: Set<String> = []
    private var openWorkspaceWindow: ((WorkspaceLaunchRequest) -> Void)?
    private var pendingRequests: [WorkspaceLaunchRequest] = []
    private(set) var preferencesManager: PreferencesManager?
    private var cachedIPCToken: String?

    private init() {}

    func configurePreferencesManager(_ manager: PreferencesManager) {
        preferencesManager = manager
        _ = loadOrCreateIPCToken()
    }

    func configureWindowOpener(_ opener: @escaping (WorkspaceLaunchRequest) -> Void) {
        openWorkspaceWindow = opener
        drainPendingRequestsIfReady()
    }

    func register(
        window: NSWindow,
        appState: AppState,
        progressState: ProgressState? = nil,
        uiState: WorkspaceUIState? = nil
    ) {
        pruneDeadWindows()
        let key = ObjectIdentifier(window)
        let archivePath = (appState.mode == .browseArchive) ? appState.sourceArchiveURL?.standardizedFileURL.path : nil
        if let archivePath {
            openingArchivePaths.remove(archivePath)
        }
        records[key] = WindowRecord(
            id: key,
            window: window,
            appState: appState,
            progressState: progressState,
            uiState: uiState,
            representedArchivePath: archivePath
        )
        applyDocumentIdentity(to: window, appState: appState)
        drainPendingRequestsIfReady()
    }

    private func drainPendingRequestsIfReady() {
        guard openWorkspaceWindow != nil, !pendingRequests.isEmpty else { return }
        let queued = pendingRequests
        pendingRequests.removeAll()
        for request in queued {
            switch request {
            case .empty:
                dispatchLaunchRequest(.empty)
            case .openArchive(let url):
                openArchive(url)
            case .compressFiles(let urls):
                openFilesToCompress(urls)
            }
        }
    }

    func update(
        window: NSWindow,
        appState: AppState,
        progressState: ProgressState? = nil,
        uiState: WorkspaceUIState? = nil
    ) {
        pruneDeadWindows()
        let key = ObjectIdentifier(window)
        let archivePath = (appState.mode == .browseArchive) ? appState.sourceArchiveURL?.standardizedFileURL.path : nil
        if let archivePath {
            openingArchivePaths.remove(archivePath)
        }
        if var record = records[key] {
            record.appState = appState
            record.progressState = progressState ?? record.progressState
            record.uiState = uiState ?? record.uiState
            record.representedArchivePath = archivePath
            records[key] = record
        } else {
            records[key] = WindowRecord(
                id: key,
                window: window,
                appState: appState,
                progressState: progressState,
                uiState: uiState,
                representedArchivePath: archivePath
            )
        }
        applyDocumentIdentity(to: window, appState: appState)
    }

    func unregister(window: NSWindow) {
        records.removeValue(forKey: ObjectIdentifier(window))
    }

    var activeWindowAppState: AppState? {
        activeWindowRecord()?.appState
    }

    var activeWindowProgressState: ProgressState? {
        activeWindowRecord()?.progressState
    }

    var activeWindowUIState: WorkspaceUIState? {
        activeWindowRecord()?.uiState
    }

    private func activeWindowRecord() -> WindowRecord? {
        pruneDeadWindows()
        if let keyWindow = NSApplication.shared.keyWindow,
           let record = records[ObjectIdentifier(keyWindow)] {
            return record
        }
        if let mainWindow = NSApplication.shared.mainWindow,
           let record = records[ObjectIdentifier(mainWindow)] {
            return record
        }
        return nil
    }

    var hasVisibleWorkspaceWindows: Bool {
        pruneDeadWindows()
        return records.values.contains { $0.window?.isVisible == true }
    }

    // MARK: - Document-Based Opening & Routing

    func openNewEmptyWindow() {
        dispatchLaunchRequest(.empty)
    }

    func presentOpenArchivePanel(from sourceAppState: AppState? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Open")
        let archiveTypes: [UTType] = [
            .zip, .gzip, .bz2, .archive,
            UTType(filenameExtension: "7z"),
            UTType(filenameExtension: "rar"),
            UTType(filenameExtension: "xz"),
            UTType(filenameExtension: "tar"),
            UTType(filenameExtension: "tgz"),
            UTType(filenameExtension: "tbz"),
            UTType(filenameExtension: "tbz2"),
            UTType(filenameExtension: "txz"),
            UTType(filenameExtension: "zst"),
            UTType(filenameExtension: "zstd"),
            UTType(filenameExtension: "tzst"),
            UTType(filenameExtension: "dmg"),
            UTType(filenameExtension: "iso"),
            UTType(filenameExtension: "xar"),
            UTType(filenameExtension: "pkg"),
            UTType(filenameExtension: "cab"),
            UTType(filenameExtension: "wim"),
            UTType(filenameExtension: "cpio"),
            UTType(filenameExtension: "lzma"),
            UTType(filenameExtension: "deb"),
            UTType(filenameExtension: "rpm"),
            UTType(filenameExtension: "lzh"),
            UTType(filenameExtension: "lha"),
            UTType(filenameExtension: "aar"),
            UTType(filenameExtension: "yaa"),
            UTType(filenameExtension: "001"),
            UTType(filenameExtension: "zipx")
        ].compactMap { $0 }
        panel.allowedContentTypes = archiveTypes

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for (index, url) in panel.urls.enumerated() {
            openArchive(url, from: index == 0 ? sourceAppState : nil)
        }
    }

    func presentChooseFilesToCompressPanel(from sourceAppState: AppState? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openFilesToCompress(panel.urls, from: sourceAppState)
    }

    /// Open an archive file following macOS Document-Based App conventions:
    /// 1. If already open in a window, bring that window to the front.
    /// 2. If invoked from an empty Welcome window (or an empty Welcome window is available), reuse it.
    /// 3. Otherwise open a brand-new independent document window.
    func openArchive(_ url: URL, from sourceAppState: AppState? = nil) {
        pruneDeadWindows()
        let standardizedPath = url.standardizedFileURL.path

        if let existing = existingWindow(forArchivePath: standardizedPath) {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if openingArchivePaths.contains(standardizedPath) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        openingArchivePaths.insert(standardizedPath)

        if let sourceAppState, sourceAppState.mode == .empty {
            Task {
                await sourceAppState.coordinator.browseArchive(at: url, appState: sourceAppState)
                finishOpeningArchive(url)
            }
            return
        }

        if sourceAppState == nil, let emptyRecord = firstEmptyWindowRecord(), let targetState = emptyRecord.appState {
            emptyRecord.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            Task {
                await targetState.coordinator.browseArchive(at: url, appState: targetState)
                finishOpeningArchive(url)
            }
            return
        }

        dispatchLaunchRequest(.openArchive(url))
    }

    func finishOpeningArchive(_ url: URL) {
        openingArchivePaths.remove(url.standardizedFileURL.path)
    }

    /// Stage local files/folders for compression in an empty window or a new compression window.
    func openFilesToCompress(_ urls: [URL], from sourceAppState: AppState? = nil) {
        guard !urls.isEmpty else { return }
        pruneDeadWindows()

        if let sourceAppState, sourceAppState.mode == .empty {
            sourceAppState.loadFiles(from: urls)
            return
        }

        if sourceAppState == nil, let emptyRecord = firstEmptyWindowRecord(), let targetState = emptyRecord.appState {
            emptyRecord.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            targetState.loadFiles(from: urls)
            return
        }

        dispatchLaunchRequest(.compressFiles(urls))
    }

    /// Route external file opens (Finder double-click, Open With, Dock drop, or `bentozip://` extension URLs).
    func openExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let customActionURLs = urls.filter { $0.scheme?.lowercased() == "bentozip" }
        if !customActionURLs.isEmpty {
            for customURL in customActionURLs {
                handleCustomActionURL(customURL)
            }
            let remainingFileURLs = urls.filter { $0.isFileURL }
            if !remainingFileURLs.isEmpty {
                openExternalURLs(remainingFileURLs)
            }
            return
        }

        let optionPressed = NSEvent.modifierFlags.contains(.option)
        let prefs = preferencesManager?.loadPreferences() ?? AppPreferences()
        var action = ArchiveOpenAction(rawValue: prefs.archiveOpenAction) ?? .browse
        if optionPressed {
            action = (action == .browse) ? .extract : .browse
        }
        let manager = preferencesManager

        Task { @MainActor in
            let allArchives = await Task.detached(priority: .userInitiated) {
                urls.allSatisfy { FormatDetector.isArchiveFile($0) }
            }.value

            if allArchives {
                if action == .extract {
                    await CompressionCoordinator().extractMultipleDirectly(
                        archiveURLs: urls,
                        preferencesManager: manager
                    ) { encryptedURL in
                        DocumentWindowRouter.shared.openArchive(encryptedURL)
                    }
                } else {
                    for url in urls {
                        openArchive(url)
                    }
                }
            } else {
                openFilesToCompress(urls)
            }
        }
    }

    private func handleCustomActionURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let action = components.host?.lowercased()
        guard action == "compress" || action == "extract" || action == "browse" else { return }

        var fileURLs: [URL] = []
        for item in components.queryItems ?? [] where item.name == "path" {
            guard let path = item.value, path.hasPrefix("/") else { continue }
            fileURLs.append(URL(fileURLWithPath: path).standardizedFileURL)
        }
        guard !fileURLs.isEmpty else { return }

        if action == "browse" {
            for fileURL in fileURLs {
                openArchive(fileURL)
            }
            return
        }

        let providedToken = (components.queryItems ?? []).first(where: { $0.name == "token" })?.value
        let expectedToken = loadOrCreateIPCToken()
        let isAuthorized = providedToken.flatMap { token in
            expectedToken.map { Self.constantTimeEquals(token, $0) }
        } ?? false

        if !isAuthorized {
            guard confirmExternalAction(action ?? "", for: fileURLs) else { return }
        }

        switch action {
        case "compress":
            openFilesToCompress(fileURLs)
        case "extract":
            BentoZipServicesProvider.shared.extractArchivesHere(fileURLs)
        default:
            return
        }
    }

    private func confirmExternalAction(_ action: String, for fileURLs: [URL]) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if action == "extract" {
            alert.messageText = String(localized: "Allow external request to extract \(fileURLs.count) item(s)?")
        } else {
            alert.messageText = String(localized: "Allow external request to compress \(fileURLs.count) item(s)?")
        }
        let previewNames = fileURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        alert.informativeText = fileURLs.count > 3 ? "\(previewNames)..." : previewNames
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func loadOrCreateIPCToken() -> String? {
        if let cachedIPCToken {
            return cachedIPCToken
        }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("BentoZip", isDirectory: true)
        let tokenURL = dir.appendingPathComponent(".ipc-token", isDirectory: false)

        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                cachedIPCToken = trimmed
                return trimmed
            }
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        cachedIPCToken = token
        return token
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhsBytes, rhsBytes) {
            diff |= (a ^ b)
        }
        return diff == 0
    }

    // MARK: - Helpers

    private func dispatchLaunchRequest(_ request: WorkspaceLaunchRequest) {
        if let openWorkspaceWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWorkspaceWindow(request)
        } else {
            pendingRequests.append(request)
        }
    }

    private func existingWindow(forArchivePath standardizedPath: String) -> NSWindow? {
        for record in records.values {
            guard let window = record.window else { continue }
            let statePath = (record.appState?.mode == .browseArchive)
                ? record.appState?.sourceArchiveURL?.standardizedFileURL.path
                : nil
            if record.representedArchivePath == standardizedPath || statePath == standardizedPath {
                return window
            }
        }
        return nil
    }

    private func firstEmptyWindowRecord() -> WindowRecord? {
        let keyWindow = NSApplication.shared.keyWindow
        if let keyWindow,
           let keyRecord = records[ObjectIdentifier(keyWindow)],
           keyRecord.appState?.mode == .empty {
            return keyRecord
        }
        return records.values.first { $0.window != nil && $0.appState?.mode == .empty }
    }

    private func applyDocumentIdentity(to window: NSWindow, appState: AppState) {
        if window.toolbarStyle != .unified {
            window.toolbarStyle = .unified
        }
        let targetSeparator: NSTitlebarSeparatorStyle = (appState.mode == .empty) ? .none : .automatic
        if window.titlebarSeparatorStyle != targetSeparator {
            window.titlebarSeparatorStyle = targetSeparator
        }
        if appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL {
            if window.representedURL != archiveURL {
                window.representedURL = archiveURL
            }
        } else if window.representedURL != nil {
            window.representedURL = nil
        }
    }

    private func pruneDeadWindows() {
        records = records.filter { $0.value.window != nil && $0.value.appState != nil }
    }
}

/// Invisible AppKit bridge that attaches native `NSWindow.representedURL` document identity
/// (titlebar proxy icon + Cmd-click path menu) and registers each workspace window with `DocumentWindowRouter`.
struct WindowDocumentBridge: NSViewRepresentable {
    let appState: AppState
    let progressState: ProgressState
    let uiState: WorkspaceUIState
    let mode: ArchiveMode
    let sourceArchiveURL: URL?

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.appState = appState
        view.progressState = progressState
        view.uiState = uiState
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.appState = appState
        nsView.progressState = progressState
        nsView.uiState = uiState
        if let window = nsView.window {
            nsView.bindCloseCallback(to: window, appState: appState)
            DocumentWindowRouter.shared.update(
                window: window,
                appState: appState,
                progressState: progressState,
                uiState: uiState
            )
        }
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: ()) {
        nsView.detachFromWindow()
    }

    @MainActor
    final class BridgeView: NSView {
        weak var appState: AppState?
        weak var progressState: ProgressState?
        weak var uiState: WorkspaceUIState?
        private weak var trackedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let previous = trackedWindow, previous !== window {
                DocumentWindowRouter.shared.unregister(window: previous)
                trackedWindow = nil
            }
            if let window, let appState {
                trackedWindow = window
                bindCloseCallback(to: window, appState: appState)
                DocumentWindowRouter.shared.register(
                    window: window,
                    appState: appState,
                    progressState: progressState,
                    uiState: uiState
                )
            }
        }

        func bindCloseCallback(to window: NSWindow, appState: AppState) {
            appState.onRequestCloseWindow = { [weak window] in
                guard let window else { return }
                if window.styleMask.contains(.closable) {
                    window.performClose(nil)
                } else {
                    window.close()
                }
            }
        }

        func detachFromWindow() {
            appState?.activeConflictPrompt?.cancel()
            appState?.activeConflictPrompt = nil
            appState?.onRequestCloseWindow = nil
            if let trackedWindow {
                DocumentWindowRouter.shared.unregister(window: trackedWindow)
                self.trackedWindow = nil
            }
        }
    }
}
