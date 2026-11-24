import AppKit
import BentoZipCore
import UniformTypeIdentifiers

extension FinderOutlineCoordinator {

    // MARK: - Double Click & Keyboard Actions

    @objc func handleDoubleClick(_ sender: Any?) {
        guard let outlineView else { return }
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let node = outlineView.item(atRow: clickedRow) as? FileNode else {
            return
        }
        if node.isDirectory {
            appState.navigateInto(node)
        } else {
            previewNodes([node])
        }
    }

    func handleSpaceKey() {
        if QuickLookHelper.shared.isVisible {
            QuickLookHelper.shared.closeIfVisible()
            return
        }
        let targets = selectedNodes()
        guard !targets.isEmpty else { return }
        previewNodes(targets)
    }

    func handleOpenKey() {
        let targets = selectedNodes()
        guard targets.count == 1, let node = targets.first else { return }
        if node.isDirectory {
            appState.navigateInto(node)
        } else {
            previewNodes([node])
        }
    }

    func handleNavigateUpKey() {
        if appState.canNavigateUp {
            appState.navigateUp()
        }
    }

    func handleDeleteKey() {
        let targets = selectedNodes()
        guard !targets.isEmpty else { return }
        if appState.mode == .compress {
            let removable = targets.filter { $0.parent == nil }
            guard !removable.isEmpty else { return }
            appState.removeNodes(removable)
        } else if appState.isWritableArchive {
            onRequestArchiveDelete(targets.map { $0.toFileEntry() })
        }
    }

    func handleEscapeKey() {
        if QuickLookHelper.shared.isVisible {
            QuickLookHelper.shared.closeIfVisible()
        } else if appState.canNavigateUp {
            appState.navigateUp()
        } else {
            appState.clearSelection()
        }
    }

    func previewNodes(_ nodes: [FileNode]) {
        if let outlineView {
            outlineView.window?.makeFirstResponder(outlineView)
        }
        QuickLookHelper.shared.preview(
            nodes: nodes,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        ) { [weak self] error in
            guard let self else { return }
            FileListTreeSupport.handleExtractionError(error, appState: self.appState)
        }
    }

    // MARK: - Drag-In Validation & Acceptance

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if (info.draggingSource as? NSView) === outlineView {
            return []
        }
        guard appState.mode == .compress || appState.isWritableArchive else {
            return []
        }
        let urls = droppedFileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }

        outlineView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        if (info.draggingSource as? NSView) === outlineView {
            return false
        }
        guard appState.mode == .compress || appState.isWritableArchive else {
            return false
        }
        let urls = droppedFileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        if appState.mode == .compress {
            appState.addEntries(from: urls)
            return true
        } else if appState.isWritableArchive {
            Task {
                await appState.coordinator.addEntries(
                    appState: appState,
                    urls: urls,
                    progressState: progressState
                )
            }
            return true
        }
        return false
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL]) ?? []
    }

    // MARK: - Drag-Out Pasteboard Writer

    func makePasteboardWriter(for item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileNode else { return nil }
        if !node.isFromArchive {
            return node.url as NSURL
        }

        let fileType: String
        if node.isDirectory {
            fileType = UTType.folder.identifier
        } else {
            fileType = UTType(filenameExtension: node.url.pathExtension)?.identifier ?? UTType.data.identifier
        }

        let provider = NSFilePromiseProvider(fileType: fileType, delegate: self)
        provider.userInfo = FilePromisePayload(
            entry: node.toFileEntry(),
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        )
        return provider
    }
}

private nonisolated final class PromiseExtractionResultBox: @unchecked Sendable {
    var result: Result<URL?, Error>?
}

// MARK: - NSFilePromiseProviderDelegate

extension FinderOutlineCoordinator: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider.userInfo as? FilePromisePayload)?.entry.name ?? "file"
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        filePromiseQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let payload = filePromiseProvider.userInfo as? FilePromisePayload else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }

        // Gate async extraction synchronously on `filePromiseQueue`'s background thread
        // so `maxConcurrentOperationCount = 2` genuinely bounds concurrent `bento7z` processes.
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = PromiseExtractionResultBox()

        Task.detached(priority: .userInitiated) {
            do {
                let extractedURL = try await DragDropManager.shared.prepareForDragThrowing(
                    payload.entry,
                    sourceArchiveURL: payload.sourceArchiveURL,
                    password: payload.password
                )
                resultBox.result = .success(extractedURL)
            } catch {
                resultBox.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()

        do {
            let extractedURL: URL?
            switch resultBox.result {
            case .success(let resolvedURL):
                extractedURL = resolvedURL
            case .failure(let error):
                throw error
            case nil:
                throw CocoaError(.fileNoSuchFile)
            }

            guard let extractedURL else {
                throw CocoaError(.fileNoSuchFile)
            }

            let fm = FileManager.default
            try? fm.removeItem(at: url)
            try fm.copyItem(at: extractedURL, to: url)
            completionHandler(nil)
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                FileListTreeSupport.handleExtractionError(error, appState: self.appState)
            }
            completionHandler(error)
        }
    }
}
