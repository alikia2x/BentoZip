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
        openNode(node)
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
        openNode(node)
    }

    func openNode(_ node: FileNode, withApplicationAt appURL: URL? = nil) {
        if node.isDirectory && appURL == nil {
            appState.navigateInto(node)
            return
        }
        if appState.mode == .browseArchive,
           appURL == nil,
           !node.isDirectory,
           FormatDetector.isArchiveFile(URL(fileURLWithPath: node.name)) {
            guard !appState.isLoading, !progressState.isOperationInProgress else { return }
            let entry = node.toFileEntry()
            Task {
                await appState.coordinator.openNestedArchive(
                    entry: entry,
                    appState: appState,
                    progressState: progressState
                )
            }
            return
        }
        let entry = node.toFileEntry()
        let archiveURL = appState.sourceArchiveURL
        let password = appState.archivePassword
        Task {
            await appState.coordinator.extractEntryForOpen(
                entry,
                archiveURL: archiveURL,
                password: password,
                appURL: appURL,
                appState: appState
            )
        }
    }

    func handleNavigateUpKey() {
        if appState.canNavigateUp {
            appState.navigateUp()
        }
    }

    func handleDeleteKey() {
        guard !appState.isLoading, !progressState.isOperationInProgress else { return }
        let targets = selectedNodes()
        guard !targets.isEmpty else { return }
        if appState.mode == .compress {
            appState.removeNodes(targets)
        } else if appState.isWritableArchive {
            onRequestArchiveDelete(targets.map { $0.toFileEntry() })
        }
    }

    func handleEscapeKey() {
        if QuickLookHelper.shared.isVisible {
            QuickLookHelper.shared.closeIfVisible()
        } else if appState.isSearchVisible || !appState.searchQuery.isEmpty {
            appState.searchQuery = ""
            appState.isSearchVisible = false
        } else if appState.canNavigateUp {
            appState.navigateUp()
        } else {
            appState.clearSelection()
        }
    }

    func handleCopyNames() {
        copyNames(selectedNodes())
    }

    func handleCopyPaths() {
        copyPaths(selectedNodes())
    }

    func copyNames(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(nodes.map(\.name).joined(separator: "\n"), forType: .string)
    }

    func copyPaths(_ nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            nodes.map { $0.archiveRelativePath ?? $0.url.path }.joined(separator: "\n"),
            forType: .string
        )
    }

    func previewNodes(_ nodes: [FileNode]) {
        if let outlineView {
            outlineView.window?.makeFirstResponder(outlineView)
        }
        let previewEntries = nodes
            .filter { !$0.isDirectory || !$0.isFromArchive }
            .map { $0.toFileEntry() }
        QuickLookHelper.shared.preview(
            nodes: nodes,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword,
            encoding: appState.selectedEncoding.iconvName
        ) { [weak self] error in
            guard let self else { return }
            FileListTreeSupport.handleExtractionError(
                error,
                appState: self.appState,
                retryAction: previewEntries.isEmpty ? nil : .preview(previewEntries)
            )
        }
    }

    // MARK: - Drag-In Validation & Acceptance

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard !appState.isLoading, !progressState.isOperationInProgress else {
            return []
        }

        if (info.draggingSource as? NSView) === outlineView {
            guard appState.isWritableArchive else { return [] }
            let dragged = activeDraggedNodes(in: outlineView)
            guard !dragged.isEmpty else { return [] }
            let draggedIDs = Set(dragged.map(\.id))

            if let node = item as? FileNode {
                let targetFolder = node.isDirectory ? node : node.parent
                if let targetFolder {
                    guard !isNodeOrDescendant(targetFolder, ofAnyIn: draggedIDs),
                          !dragged.allSatisfy({ $0.parent?.id == targetFolder.id }) else {
                        return []
                    }
                    outlineView.setDropItem(targetFolder, dropChildIndex: NSOutlineViewDropOnItemIndex)
                    return .move
                }
            }

            let currentNavID = appState.navigationNodes.last?.id
            guard dragged.contains(where: { $0.parent?.id != currentNavID }) else {
                return []
            }
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        guard appState.mode == .compress || appState.isWritableArchive else {
            return []
        }
        let urls = droppedFileURLs(from: info.draggingPasteboard)
        guard !urls.isEmpty else { return [] }

        if appState.isWritableArchive, let node = item as? FileNode {
            let folderNode = node.isDirectory ? node : node.parent
            if let folderNode {
                let row = outlineView.row(forItem: folderNode)
                if row >= 0 {
                    outlineView.setDropRow(row, dropOperation: .on)
                    return .copy
                }
            }
        }

        outlineView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard !appState.isLoading, !progressState.isOperationInProgress else {
            return false
        }

        if (info.draggingSource as? NSView) === outlineView {
            guard appState.isWritableArchive else { return false }
            let dragged = activeDraggedNodes(in: outlineView)
            guard !dragged.isEmpty else { return false }
            let draggedIDs = Set(dragged.map(\.id))

            let targetDir: String
            if let node = item as? FileNode,
               let targetFolder = node.isDirectory ? node : node.parent {
                guard !isNodeOrDescendant(targetFolder, ofAnyIn: draggedIDs),
                      let rel = targetFolder.archiveRelativePath else {
                    return false
                }
                targetDir = normalizedRelativePrefix(rel)
            } else {
                targetDir = appState.currentSubfolderPath
            }

            let entries = dragged.map { $0.toFileEntry() }
            draggingSessionNodes.removeAll()
            Task {
                await appState.coordinator.moveEntries(
                    appState: appState,
                    entries: entries,
                    toTargetDir: targetDir,
                    progressState: progressState
                )
            }
            return true
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
            let targetPrefix: String
            if let node = item as? FileNode,
               let folderNode = node.isDirectory ? node : node.parent,
               let relPath = folderNode.archiveRelativePath {
                targetPrefix = normalizedRelativePrefix(relPath)
            } else {
                targetPrefix = appState.currentSubfolderPath
            }
            Task {
                await appState.coordinator.addEntries(
                    appState: appState,
                    urls: urls,
                    targetPrefix: targetPrefix,
                    progressState: progressState
                )
            }
            return true
        }
        return false
    }

    private func activeDraggedNodes(in outlineView: NSOutlineView) -> [FileNode] {
        draggingSessionNodes.isEmpty ? selectedNodes(in: outlineView) : draggingSessionNodes
    }

    private func isNodeOrDescendant(_ candidate: FileNode, ofAnyIn ancestorIDs: Set<UUID>) -> Bool {
        var current: FileNode? = candidate
        while let node = current {
            if ancestorIDs.contains(node.id) {
                return true
            }
            current = node.parent
        }
        return false
    }

    private func normalizedRelativePrefix(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        return s == "." ? "" : s
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
            password: appState.archivePassword,
            encoding: appState.selectedEncoding.iconvName
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
                    password: payload.password,
                    encoding: payload.encoding
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
                let retryAction: PendingPasswordAction? = payload.sourceArchiveURL.map {
                    .extract($0, entries: [payload.entry], chooseDestination: true)
                }
                FileListTreeSupport.handleExtractionError(
                    error,
                    appState: self.appState,
                    retryAction: retryAction
                )
            }
            completionHandler(error)
        }
    }
}
