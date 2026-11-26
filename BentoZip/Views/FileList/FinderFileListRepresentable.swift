import AppKit
import BentoZipCore
import SwiftUI

struct FinderFileListRepresentable: NSViewRepresentable {
    let appState: AppState
    let progressState: ProgressState
    let uiState: WorkspaceUIState
    let mode: ArchiveMode
    let sourceArchiveURL: URL?
    let showInspector: Bool
    let treeStructureRevision: UInt64
    let nodeUpdateRevision: UInt64
    let isSearchVisible: Bool
    let outlineFocusRequestID: UInt64
    let selectedEntryIDs: Set<UUID>
    let onRequestArchiveDelete: ([FileEntry]) -> Void

    func makeCoordinator() -> FinderOutlineCoordinator {
        FinderOutlineCoordinator(
            appState: appState,
            progressState: progressState,
            uiState: uiState,
            onRequestArchiveDelete: onRequestArchiveDelete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = FinderOutlineView()
        let coordinator = context.coordinator

        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = NSSize(width: 8, height: 0)
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(appState.isWritableArchive ? .move : [], forLocal: true)
        outlineView.registerForDraggedTypes([.fileURL])

        let nameColumn = makeColumn(
            id: FinderColumnID.name,
            title: String(localized: "Name"),
            width: 220,
            minWidth: 140,
            sortKey: "name",
            ascending: true,
            alignment: .left,
            resizingMask: [.autoresizingMask, .userResizingMask]
        )
        let dateColumn = makeColumn(
            id: FinderColumnID.date,
            title: String(localized: "Date Modified"),
            width: 136,
            minWidth: 108,
            sortKey: "date",
            ascending: false,
            alignment: .left,
            resizingMask: .userResizingMask
        )
        let sizeColumn = makeColumn(
            id: FinderColumnID.size,
            title: String(localized: "Size"),
            width: 76,
            minWidth: 64,
            sortKey: "size",
            ascending: false,
            alignment: .right,
            resizingMask: .userResizingMask
        )
        let packedColumn = makeColumn(
            id: FinderColumnID.packed,
            title: String(localized: "Packed"),
            width: 76,
            minWidth: 64,
            sortKey: "packed",
            ascending: false,
            alignment: .right,
            resizingMask: .userResizingMask
        )
        packedColumn.isHidden = (mode != .browseArchive)

        let ratioColumn = makeColumn(
            id: FinderColumnID.ratio,
            title: String(localized: "Ratio"),
            width: 64,
            minWidth: 52,
            sortKey: "ratio",
            ascending: false,
            alignment: .right,
            resizingMask: .userResizingMask
        )
        ratioColumn.isHidden = true

        let crcColumn = makeColumn(
            id: FinderColumnID.crc,
            title: String(localized: "CRC32"),
            width: 82,
            minWidth: 68,
            sortKey: "crc",
            ascending: true,
            alignment: .left,
            resizingMask: .userResizingMask
        )
        crcColumn.isHidden = true

        let kindColumn = makeColumn(
            id: FinderColumnID.kind,
            title: String(localized: "Kind"),
            width: 100,
            minWidth: 72,
            sortKey: "kind",
            ascending: true,
            alignment: .left,
            resizingMask: .userResizingMask
        )

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(dateColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.addTableColumn(packedColumn)
        outlineView.addTableColumn(ratioColumn)
        outlineView.addTableColumn(crcColumn)
        outlineView.addTableColumn(kindColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.autosaveName = "BentoZipFinderOutline"
        outlineView.autosaveTableColumns = true

        let prefs = appState.preferencesManager?.loadPreferences()
        let sortKey = prefs?.sortColumnKey ?? "name"
        let sortAscending = prefs?.sortAscending ?? true
        let initialSort = NSSortDescriptor(key: sortKey, ascending: sortAscending)
        coordinator.currentSortDescriptor = initialSort
        outlineView.sortDescriptors = [initialSort]

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(FinderOutlineCoordinator.handleDoubleClick(_:))

        outlineView.onSpace = { [weak coordinator] in coordinator?.handleSpaceKey() }
        outlineView.onOpen = { [weak coordinator] in coordinator?.handleOpenKey() }
        outlineView.onNavigateUp = { [weak coordinator] in coordinator?.handleNavigateUpKey() }
        outlineView.onDelete = { [weak coordinator] in coordinator?.handleDeleteKey() }
        outlineView.onEscape = { [weak coordinator] in coordinator?.handleEscapeKey() }
        outlineView.onCopyNames = { [weak coordinator] in coordinator?.handleCopyNames() }
        outlineView.onCopyPaths = { [weak coordinator] in coordinator?.handleCopyPaths() }
        outlineView.onContextMenu = { [weak coordinator] nodes in
            coordinator?.makeContextMenu(for: nodes)
        }
        outlineView.onMovedToWindow = { [weak coordinator] in
            coordinator?.handleMovedToWindow()
        }
        outlineView.onBecameQuickLookOwner = { [weak coordinator] in
            coordinator?.handleBecameQuickLookOwner()
        }

        coordinator.outlineView = outlineView
        coordinator.packedColumn = packedColumn
        coordinator.ratioColumn = ratioColumn
        coordinator.crcColumn = crcColumn
        coordinator.configureColumnsAndHeaderMenu(for: outlineView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        coordinator.syncFromModel()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.appState = appState
        coordinator.progressState = progressState
        coordinator.uiState = uiState
        coordinator.onRequestArchiveDelete = onRequestArchiveDelete
        coordinator.syncFromModel()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: FinderOutlineCoordinator) {
        coordinator.tearDown()
    }

    private func makeColumn(
        id: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        sortKey: String,
        ascending: Bool,
        alignment: NSTextAlignment,
        resizingMask: NSTableColumn.ResizingOptions
    ) -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.resizingMask = resizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending)
        column.headerCell.alignment = alignment
        return column
    }
}
