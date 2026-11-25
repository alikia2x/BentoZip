import AppKit
import BentoZipCore
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
        var representedArchivePath: String?
    }

    private var records: [ObjectIdentifier: WindowRecord] = [:]
    private var openWorkspaceWindow: ((WorkspaceLaunchRequest) -> Void)?
    private var pendingRequests: [WorkspaceLaunchRequest] = []

    private init() {}

    func configureWindowOpener(_ opener: @escaping (WorkspaceLaunchRequest) -> Void) {
        openWorkspaceWindow = opener
        drainPendingRequestsIfReady()
    }

    func register(window: NSWindow, appState: AppState) {
        pruneDeadWindows()
        let key = ObjectIdentifier(window)
        let archivePath = (appState.mode == .browseArchive) ? appState.sourceArchiveURL?.standardizedFileURL.path : nil
        records[key] = WindowRecord(
            id: key,
            window: window,
            appState: appState,
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

    func update(window: NSWindow, appState: AppState) {
        pruneDeadWindows()
        let key = ObjectIdentifier(window)
        let archivePath = (appState.mode == .browseArchive) ? appState.sourceArchiveURL?.standardizedFileURL.path : nil
        if var record = records[key] {
            record.appState = appState
            record.representedArchivePath = archivePath
            records[key] = record
        } else {
            records[key] = WindowRecord(
                id: key,
                window: window,
                appState: appState,
                representedArchivePath: archivePath
            )
        }
        applyDocumentIdentity(to: window, appState: appState)
    }

    func unregister(window: NSWindow) {
        records.removeValue(forKey: ObjectIdentifier(window))
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

        if let sourceAppState, sourceAppState.mode == .empty {
            Task {
                await sourceAppState.coordinator.browseArchive(at: url, appState: sourceAppState)
            }
            return
        }

        if sourceAppState == nil, let emptyRecord = firstEmptyWindowRecord(), let targetState = emptyRecord.appState {
            emptyRecord.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            Task {
                await targetState.coordinator.browseArchive(at: url, appState: targetState)
            }
            return
        }

        dispatchLaunchRequest(.openArchive(url))
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

    /// Route external file opens (Finder double-click, Open With, Dock drop).
    func openExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let allArchives = urls.allSatisfy { FormatDetector.isArchiveFile($0) }
        if allArchives {
            for url in urls {
                openArchive(url)
            }
        } else {
            openFilesToCompress(urls)
        }
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
    let mode: ArchiveMode
    let sourceArchiveURL: URL?

    func makeNSView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: BridgeView, context: Context) {
        nsView.appState = appState
        if let window = nsView.window {
            DocumentWindowRouter.shared.update(window: window, appState: appState)
        }
    }

    static func dismantleNSView(_ nsView: BridgeView, coordinator: ()) {
        nsView.detachFromWindow()
    }

    @MainActor
    final class BridgeView: NSView {
        weak var appState: AppState?
        private weak var trackedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let previous = trackedWindow, previous !== window {
                DocumentWindowRouter.shared.unregister(window: previous)
                trackedWindow = nil
            }
            if let window, let appState {
                trackedWindow = window
                DocumentWindowRouter.shared.register(window: window, appState: appState)
            }
        }

        func detachFromWindow() {
            if let trackedWindow {
                DocumentWindowRouter.shared.unregister(window: trackedWindow)
                self.trackedWindow = nil
            }
        }
    }
}
