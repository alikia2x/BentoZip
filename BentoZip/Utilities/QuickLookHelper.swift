import AppKit
import BentoZipCore
import QuickLookUI

@MainActor
final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookHelper()

    private weak var activeOutlineView: FinderOutlineView?
    private var previewURLs: [URL] = []
    private var requestID: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var isPresentingPanel = false

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible == true)
    }

    // MARK: - Responder Chain Control

    func beginControl(panel: QLPreviewPanel, owner: FinderOutlineView) {
        let ownerChanged = (activeOutlineView !== owner)
        activeOutlineView = owner
        panel.dataSource = self
        panel.delegate = self
        if ownerChanged && panel.isVisible && !isPresentingPanel {
            owner.onBecameQuickLookOwner?()
        }
    }

    func endControl(panel: QLPreviewPanel, owner: FinderOutlineView) {
        if activeOutlineView === owner {
            activeOutlineView = nil
        }
        panel.dataSource = nil
        panel.delegate = nil
    }

    func detachOwner(_ owner: FinderOutlineView) {
        guard activeOutlineView === owner else { return }
        activeTask?.cancel()
        activeTask = nil
        requestID &+= 1
        activeOutlineView = nil
        previewURLs = []
        if isVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
    }

    func closeIfVisible() {
        guard isVisible, let panel = QLPreviewPanel.shared() else { return }
        requestID &+= 1
        activeTask?.cancel()
        activeTask = nil
        panel.orderOut(nil)
    }

    func closeIfVisible(for owner: FinderOutlineView) {
        guard activeOutlineView === owner || activeOutlineView == nil else { return }
        closeIfVisible()
    }

    // MARK: - Preview Presentation

    func preview(
        nodes: [FileNode],
        sourceArchiveURL: URL?,
        password: String?,
        encoding: String? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        let previewable = nodes.filter { !$0.isDirectory || !$0.isFromArchive }
        guard !previewable.isEmpty else { return }

        requestID &+= 1
        let currentRequestID = requestID
        activeTask?.cancel()

        // Fast path: local items open synchronously without async hops.
        if previewable.allSatisfy({ !$0.isFromArchive }) {
            presentPanel(with: previewable.map(\.url), makeKeyIfHidden: true)
            return
        }

        let snapshots = previewable.map { $0.toFileEntry() }
        extractAndDisplay(
            snapshots: snapshots,
            sourceArchiveURL: sourceArchiveURL,
            password: password,
            encoding: encoding,
            requestID: currentRequestID,
            makeKeyIfHidden: true,
            onError: onError
        )
    }

    func togglePreview(
        nodes: [FileNode],
        sourceArchiveURL: URL?,
        password: String?,
        encoding: String? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        if isVisible {
            closeIfVisible()
            return
        }
        preview(
            nodes: nodes,
            sourceArchiveURL: sourceArchiveURL,
            password: password,
            encoding: encoding,
            onError: onError
        )
    }

    func updateSelectionIfVisible(
        nodes: [FileNode],
        sourceArchiveURL: URL?,
        password: String?,
        encoding: String? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        guard isVisible else { return }

        let previewable = nodes.filter { !$0.isDirectory || !$0.isFromArchive }
        requestID &+= 1
        let currentRequestID = requestID
        activeTask?.cancel()

        guard !previewable.isEmpty else {
            previewURLs = []
            QLPreviewPanel.shared()?.reloadData()
            return
        }

        if previewable.allSatisfy({ !$0.isFromArchive }) {
            presentPanel(with: previewable.map(\.url), makeKeyIfHidden: false)
            return
        }

        let snapshots = previewable.map { $0.toFileEntry() }
        extractAndDisplay(
            snapshots: snapshots,
            sourceArchiveURL: sourceArchiveURL,
            password: password,
            encoding: encoding,
            requestID: currentRequestID,
            makeKeyIfHidden: false,
            onError: onError
        )
    }

    private func extractAndDisplay(
        snapshots: [FileEntry],
        sourceArchiveURL: URL?,
        password: String?,
        encoding: String?,
        requestID currentRequestID: UInt64,
        makeKeyIfHidden: Bool,
        onError: ((Error) -> Void)?
    ) {
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var resolvedURLs: [URL] = []
            for entry in snapshots {
                guard !Task.isCancelled, self.requestID == currentRequestID else { return }
                do {
                    if let url = try await DragDropManager.shared.prepareForDragThrowing(
                        entry,
                        sourceArchiveURL: sourceArchiveURL,
                        password: password,
                        encoding: encoding
                    ) {
                        resolvedURLs.append(url)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.requestID == currentRequestID else { return }
                    onError?(error)
                    return
                }
            }

            guard !Task.isCancelled,
                  self.requestID == currentRequestID,
                  !resolvedURLs.isEmpty else {
                return
            }

            if !makeKeyIfHidden && !self.isVisible {
                return
            }
            self.presentPanel(with: resolvedURLs, makeKeyIfHidden: makeKeyIfHidden)
        }
    }

    private func presentPanel(with urls: [URL], makeKeyIfHidden: Bool) {
        previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        isPresentingPanel = true
        panel.updateController()
        isPresentingPanel = false
        if panel.dataSource !== self {
            panel.dataSource = self
        }
        if panel.delegate !== self {
            panel.delegate = self
        }
        panel.reloadData()
        if makeKeyIfHidden && !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard previewURLs.indices.contains(index) else { return nil }
            return previewURLs[index] as NSURL
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard let event,
                  event.type == .keyDown,
                  let activeOutlineView else {
                return false
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            switch event.keyCode {
            case 125, 126: // Down, Up arrows
                guard modifiers.isEmpty || modifiers == .command || modifiers == .shift else {
                    return false
                }
                activeOutlineView.keyDown(with: event)
                return true
            case 123, 124: // Left, Right arrows
                guard modifiers.isEmpty, previewURLs.count <= 1 else {
                    return false
                }
                activeOutlineView.keyDown(with: event)
                return true
            default:
                return false
            }
        }
    }
}
