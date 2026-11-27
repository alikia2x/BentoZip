import AppKit
import BentoZipCore

struct FilePromisePayload: Sendable {
    let entry: FileEntry
    let sourceArchiveURL: URL?
    let password: String?
    let encoding: String?
}

@MainActor
final class FinderOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var outlineView: FinderOutlineView?
    weak var alternatePreviewOwner: NSView?
    weak var packedColumn: NSTableColumn?
    weak var ratioColumn: NSTableColumn?
    weak var crcColumn: NSTableColumn?
    var draggingSessionNodes: [FileNode] = []

    private static let hiddenColumnsDefaultsKey = "BentoZipOutlineHiddenColumns"
    private var hiddenColumnIDs: Set<String> = {
        if let stored = UserDefaults.standard.stringArray(forKey: "BentoZipOutlineHiddenColumns") {
            return Set(stored)
        }
        return [FinderColumnID.ratio.rawValue, FinderColumnID.crc.rawValue]
    }()

    var appState: AppState
    var progressState: ProgressState
    var uiState: WorkspaceUIState
    var onRequestArchiveDelete: ([FileEntry]) -> Void

    private var lastTreeStructureRevision: UInt64 = .max
    private var lastNodeUpdateRevision: UInt64 = 0
    private var lastMode: ArchiveMode?
    private var lastArchiveURL: URL?
    private var lastShowInspector: Bool?
    private var lastSearchVisible: Bool = false
    private var lastOutlineFocusRequestID: UInt64 = 0
    private var isUpdatingSelectionFromModel = false
    private var needsInitialWindowFocus = true
    private var hasScheduledDeferredFocusCheck = false
    private var sortedRoots: [FileNode] = []
    private var sortedChildrenCache: [UUID: [FileNode]] = [:]
    var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true)

    nonisolated let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.bentozip.file-promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(
        appState: AppState,
        progressState: ProgressState,
        uiState: WorkspaceUIState,
        onRequestArchiveDelete: @escaping ([FileEntry]) -> Void
    ) {
        self.appState = appState
        self.progressState = progressState
        self.uiState = uiState
        self.onRequestArchiveDelete = onRequestArchiveDelete
        super.init()
        bindResumePreview()
    }

    func tearDown() {
        needsInitialWindowFocus = false
        hasScheduledDeferredFocusCheck = false
        appState.onResumePreview = nil
        if let outlineView {
            outlineView.dataSource = nil
            outlineView.delegate = nil
            outlineView.target = nil
            QuickLookHelper.shared.detachOwner(outlineView)
        }
    }

    func bindResumePreview() {
        appState.onResumePreview = { [weak self] entries in
            guard let self else { return }
            let nodes = entries.map { self.appState.node(for: $0.id) ?? FileNode(entry: $0) }
            self.previewNodes(nodes)
        }
    }

    func handleMovedToWindow() {
        claimFirstResponderIfAppropriate()
    }

    func handleBecameQuickLookOwner() {
        let nodes = selectedNodes()
        let previewEntries = nodes
            .filter { !$0.isDirectory || !$0.isFromArchive }
            .map { $0.toFileEntry() }
        QuickLookHelper.shared.updateSelectionIfVisible(
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

    // MARK: - Model -> OutlineView Synchronization

    func syncFromModel() {
        guard let outlineView else { return }
        bindResumePreview()

        outlineView.setDraggingSourceOperationMask(appState.isWritableArchive ? .move : [], forLocal: true)
        applyColumnVisibility(for: outlineView)
        outlineView.fitColumnsToVisibleWidthIfNeeded()

        let modeOrArchiveChanged = (lastMode != appState.mode || lastArchiveURL != appState.sourceArchiveURL)
        lastMode = appState.mode
        lastArchiveURL = appState.sourceArchiveURL

        let inspectorOpenedInCompress = (lastShowInspector == false && appState.showInspector && appState.mode == .compress)
        lastShowInspector = appState.showInspector

        let searchDismissed = (lastSearchVisible && !appState.isSearchVisible)
        lastSearchVisible = appState.isSearchVisible

        let outlineFocusRequested = (lastOutlineFocusRequestID != uiState.outlineFocusRequestID)
        if outlineFocusRequested {
            lastOutlineFocusRequestID = uiState.outlineFocusRequestID
        }

        if modeOrArchiveChanged {
            needsInitialWindowFocus = true
            QuickLookHelper.shared.closeIfVisible(for: outlineView)
        } else if inspectorOpenedInCompress {
            needsInitialWindowFocus = true
        }

        if lastTreeStructureRevision != appState.treeStructureRevision {
            lastTreeStructureRevision = appState.treeStructureRevision
            lastNodeUpdateRevision = appState.nodeUpdateRevision
            rebuildRootsAndReload(in: outlineView)
            syncSelectionFromModel(in: outlineView)
            if outlineFocusRequested {
                focusOutlineAndSelectFirstRowIfNeeded(in: outlineView)
            } else {
                claimFirstResponderIfAppropriate()
            }
            return
        }

        if lastNodeUpdateRevision != appState.nodeUpdateRevision {
            let previousRevision = lastNodeUpdateRevision
            lastNodeUpdateRevision = appState.nodeUpdateRevision
            applyIncrementalUpdates(since: previousRevision, in: outlineView)
        }

        syncSelectionFromModel(in: outlineView)

        if outlineFocusRequested {
            focusOutlineAndSelectFirstRowIfNeeded(in: outlineView)
        } else if inspectorOpenedInCompress || searchDismissed {
            claimFirstResponderIfAppropriate()
        }
    }

    private func focusOutlineAndSelectFirstRowIfNeeded(in outlineView: NSOutlineView) {
        outlineView.window?.makeFirstResponder(outlineView)
        if outlineView.selectedRowIndexes.isEmpty,
           outlineView.numberOfRows > 0,
           let firstNode = outlineView.item(atRow: 0) as? FileNode {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            appState.selectedEntryIDs = [firstNode.id]
        }
    }

    private func rebuildRootsAndReload(in outlineView: NSOutlineView) {
        sortedRoots = FileListTreeSupport.sortNodes(appState.displayedNodes, using: currentSortDescriptor)
        sortedChildrenCache.removeAll(keepingCapacity: true)
        let previousGuard = isUpdatingSelectionFromModel
        isUpdatingSelectionFromModel = true
        defer { isUpdatingSelectionFromModel = previousGuard }
        outlineView.reloadData()
    }

    private func applyIncrementalUpdates(since revision: UInt64, in outlineView: NSOutlineView) {
        guard let events = appState.nodeUpdates(since: revision) else {
            rebuildRootsAndReload(in: outlineView)
            syncSelectionFromModel(in: outlineView)
            return
        }

        let currentNavID = appState.navigationNodes.last?.id
        if let currentNavID,
           events.contains(where: { $0.nodeID == currentNavID && $0.reloadChildren }) {
            rebuildRootsAndReload(in: outlineView)
            syncSelectionFromModel(in: outlineView)
            return
        }

        let previousGuard = isUpdatingSelectionFromModel
        isUpdatingSelectionFromModel = true
        defer { isUpdatingSelectionFromModel = previousGuard }
        for event in events {
            if event.reloadChildren {
                sortedChildrenCache.removeValue(forKey: event.nodeID)
            }
            guard let node = appState.node(for: event.nodeID) else { continue }
            if outlineView.row(forItem: node) >= 0 {
                outlineView.reloadItem(node, reloadChildren: event.reloadChildren)
            }
        }
    }

    private func syncSelectionFromModel(in outlineView: NSOutlineView) {
        let modelIDs = appState.selectedEntryIDs
        let currentIDs = Set(selectedNodes(in: outlineView).map(\.id))
        guard modelIDs != currentIDs else { return }

        let targetIndexes = NSMutableIndexSet()
        for id in modelIDs {
            if let node = appState.node(for: id) {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    targetIndexes.add(row)
                }
            }
        }

        let previousGuard = isUpdatingSelectionFromModel
        isUpdatingSelectionFromModel = true
        defer { isUpdatingSelectionFromModel = previousGuard }
        outlineView.selectRowIndexes(targetIndexes as IndexSet, byExtendingSelection: false)
    }

    private func claimFirstResponderIfAppropriate() {
        guard let outlineView,
              let window = outlineView.window,
              window.attachedSheet == nil,
              !appState.isSearchVisible,
              !(window.firstResponder is NSText) else {
            needsInitialWindowFocus = false
            return
        }

        if window.firstResponder !== outlineView {
            window.makeFirstResponder(outlineView)
        }

        // One next-runloop re-check handles SwiftUI Form TextFields claiming focus
        // right after initial mount or inspector opening, without arbitrary timers.
        guard needsInitialWindowFocus, !hasScheduledDeferredFocusCheck else { return }
        hasScheduledDeferredFocusCheck = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledDeferredFocusCheck = false
            guard self.needsInitialWindowFocus,
                  let outlineView = self.outlineView,
                  let window = outlineView.window,
                  window.attachedSheet == nil,
                  !self.appState.isSearchVisible,
                  !(window.firstResponder is NSText) else {
                self.needsInitialWindowFocus = false
                return
            }
            self.needsInitialWindowFocus = false
            if window.firstResponder !== outlineView {
                window.makeFirstResponder(outlineView)
            }
        }
    }

    func selectedNodes(in outlineView: NSOutlineView? = nil) -> [FileNode] {
        guard let view = outlineView ?? self.outlineView else { return appState.selectedNodes }
        return view.selectedRowIndexes.compactMap { view.item(atRow: $0) as? FileNode }
    }

    private func sortedChildren(of node: FileNode) -> [FileNode] {
        if let cached = sortedChildrenCache[node.id] {
            return cached
        }
        let sorted = FileListTreeSupport.sortNodes(appState.visibleChildren(of: node), using: currentSortDescriptor)
        sortedChildrenCache[node.id] = sorted
        return sorted
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sortedRoots.count
        }
        guard let node = item as? FileNode else { return 0 }
        return sortedChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let hasSearch = !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSearch {
            return false
        }
        return (item as? FileNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sortedRoots[index]
        }
        if let node = item as? FileNode {
            return sortedChildren(of: node)[index]
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        var expandedNodes: [FileNode] = []
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode,
               outlineView.isItemExpanded(node) {
                expandedNodes.append(node)
            }
        }

        currentSortDescriptor = outlineView.sortDescriptors.first
        if let descriptor = currentSortDescriptor, let key = descriptor.key {
            appState.preferencesManager?.updatePreferences { prefs in
                prefs.sortColumnKey = key
                prefs.sortAscending = descriptor.ascending
            }
        }
        do {
            let previousGuard = isUpdatingSelectionFromModel
            isUpdatingSelectionFromModel = true
            defer { isUpdatingSelectionFromModel = previousGuard }

            rebuildRootsAndReload(in: outlineView)

            for node in expandedNodes {
                if outlineView.row(forItem: node) >= 0 {
                    outlineView.expandItem(node)
                }
            }
        }
        syncSelectionFromModel(in: outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        makePasteboardWriter(for: item)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        draggingSessionNodes = draggedItems.compactMap { $0 as? FileNode }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        draggingSessionNodes.removeAll()
    }

    // MARK: - Header Column Visibility Menu

    func configureColumnsAndHeaderMenu(for outlineView: NSOutlineView) {
        applyColumnVisibility(for: outlineView)

        let menu = NSMenu(title: String(localized: "Columns"))
        menu.delegate = self
        menu.autoenablesItems = false

        let items: [(NSUserInterfaceItemIdentifier, String)] = [
            (FinderColumnID.date, String(localized: "Date Modified")),
            (FinderColumnID.size, String(localized: "Size")),
            (FinderColumnID.packed, String(localized: "Packed")),
            (FinderColumnID.ratio, String(localized: "Ratio")),
            (FinderColumnID.crc, String(localized: "CRC32")),
            (FinderColumnID.kind, String(localized: "Kind")),
        ]
        for (id, title) in items {
            let item = NSMenuItem(title: title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            menu.addItem(item)
        }
        outlineView.headerView?.menu = menu
    }

    func applyColumnVisibility(for outlineView: NSOutlineView) {
        let archiveOnlyIDs: Set<String> = [
            FinderColumnID.packed.rawValue,
            FinderColumnID.ratio.rawValue,
            FinderColumnID.crc.rawValue,
        ]
        for column in outlineView.tableColumns where column.identifier != FinderColumnID.name {
            let id = column.identifier.rawValue
            if archiveOnlyIDs.contains(id) && appState.mode != .browseArchive {
                column.isHidden = true
            } else {
                column.isHidden = hiddenColumnIDs.contains(id)
            }
        }
        if let finderOutline = outlineView as? FinderOutlineView {
            finderOutline.fitColumnsToVisibleWidthIfNeeded()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let archiveOnlyIDs: Set<String> = [
            FinderColumnID.packed.rawValue,
            FinderColumnID.ratio.rawValue,
            FinderColumnID.crc.rawValue,
        ]
        for item in menu.items {
            guard let id = item.representedObject as? String else { continue }
            let isArchiveOnly = archiveOnlyIDs.contains(id)
            item.isEnabled = !isArchiveOnly || appState.mode == .browseArchive
            if isArchiveOnly && appState.mode != .browseArchive {
                item.state = .off
            } else {
                item.state = hiddenColumnIDs.contains(id) ? .off : .on
            }
        }
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if hiddenColumnIDs.contains(id) {
            hiddenColumnIDs.remove(id)
        } else {
            hiddenColumnIDs.insert(id)
        }
        UserDefaults.standard.set(Array(hiddenColumnIDs), forKey: Self.hiddenColumnsDefaultsKey)
        if let outlineView {
            applyColumnVisibility(for: outlineView)
            outlineView.fitColumnsToVisibleWidthIfNeeded()
        }
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let columnID = tableColumn?.identifier,
              let node = item as? FileNode else {
            return nil
        }
        let isSearching = !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return FinderOutlineCellFactory.makeView(
            for: columnID,
            node: node,
            in: outlineView,
            isSearching: isSearching
        )
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        appState.loadChildrenIfNeeded(for: node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelectionFromModel, let outlineView else { return }
        let nodes = selectedNodes(in: outlineView)
        appState.selectedEntryIDs = Set(nodes.map(\.id))

        let previewEntries = nodes
            .filter { !$0.isDirectory || !$0.isFromArchive }
            .map { $0.toFileEntry() }
        QuickLookHelper.shared.updateSelectionIfVisible(
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
}
