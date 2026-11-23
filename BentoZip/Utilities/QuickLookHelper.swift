import AppKit
import BentoZipCore
import QuickLookUI

@MainActor
final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookHelper()

    private var previewURLs: [URL] = []
    private var requestID: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func preview(
        entries: [FileEntry],
        sourceArchiveURL: URL?,
        password: String?,
        onError: ((Error) -> Void)? = nil
    ) {
        let previewable = entries.filter { !$0.isDirectory }
        guard !previewable.isEmpty else { return }

        requestID &+= 1
        let currentRequestID = requestID
        activeTask?.cancel()

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var resolvedURLs: [URL] = []
            for entry in previewable {
                guard !Task.isCancelled, self.requestID == currentRequestID else { return }
                do {
                    if let url = try await DragDropManager.shared.prepareForDragThrowing(
                        entry,
                        sourceArchiveURL: sourceArchiveURL,
                        password: password
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

            guard !Task.isCancelled, self.requestID == currentRequestID, !resolvedURLs.isEmpty else {
                return
            }
            self.presentPanel(with: resolvedURLs)
        }
    }

    func togglePreview(
        entries: [FileEntry],
        sourceArchiveURL: URL?,
        password: String?,
        onError: ((Error) -> Void)? = nil
    ) {
        if let panel = QLPreviewPanel.shared(),
           QLPreviewPanel.sharedPreviewPanelExists(),
           panel.isVisible {
            requestID &+= 1
            activeTask?.cancel()
            panel.orderOut(nil)
            return
        }
        preview(
            entries: entries,
            sourceArchiveURL: sourceArchiveURL,
            password: password,
            onError: onError
        )
    }

    private func presentPanel(with urls: [URL]) {
        self.previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            previewURLs[index] as NSURL
        }
    }
}
