import AppKit
import BentoZipCore
import QuickLookUI
import SwiftUI

struct FinderGridView: NSViewRepresentable {
    let appState: AppState
    let progressState: ProgressState
    let uiState: WorkspaceUIState
    let displayedNodes: [FileNode]
    let nodeUpdateRevision: UInt64
    let selectedEntryIDs: Set<UUID>
    let focusRequestID: UInt64
    let onRequestArchiveDelete: ([FileEntry]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: FinderOutlineCoordinator(
            appState: appState,
            progressState: progressState,
            uiState: uiState,
            onRequestArchiveDelete: onRequestArchiveDelete
        ))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewGridLayout()
        layout.minimumItemSize = NSSize(width: 100, height: 108)
        layout.maximumItemSize = layout.minimumItemSize
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.margins = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let collection = FileIconCollectionView()
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.controlBackgroundColor]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.autoresizingMask = [.width]
        collection.setAccessibilityIdentifier("workspace.icon-view")
        collection.register(FileIconCollectionItem.self, forItemWithIdentifier: FileIconCollectionItem.identifier)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([], forLocal: true)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.gridCoordinator = context.coordinator
        context.coordinator.actions.alternatePreviewOwner = collection

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        collection.frame = scrollView.contentView.bounds
        scrollView.documentView = collection
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let collection = scrollView.documentView as? FileIconCollectionView else { return }
        let coordinator = context.coordinator
        coordinator.actions.bindResumePreview()
        coordinator.actions.onRequestArchiveDelete = onRequestArchiveDelete
        coordinator.sync(from: self, in: collection)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let collection = scrollView.documentView as? FileIconCollectionView else { return }
        QuickLookHelper.shared.detachOwner(collection)
        collection.delegate = nil
        collection.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let actions: FinderOutlineCoordinator
        private var sourceIDs: [UUID] = []
        private var navigationIDs: [UUID] = []
        private var nodeRevision: UInt64?
        private var focusRequestID: UInt64?
        private var sortDescriptor: NSSortDescriptor?
        private var syncing = false
        private var nodes: [FileNode] = []

        init(actions: FinderOutlineCoordinator) {
            self.actions = actions
        }

        fileprivate func sync(from view: FinderGridView, in collection: FileIconCollectionView) {
            let prefs = actions.appState.preferencesManager?.loadPreferences()
            let descriptor = NSSortDescriptor(
                key: prefs?.sortColumnKey ?? "name",
                ascending: prefs?.sortAscending ?? true
            )
            let ids = view.displayedNodes.map(\.id)
            syncing = true
            defer { syncing = false }

            if ids != sourceIDs || view.nodeUpdateRevision != nodeRevision || descriptor != sortDescriptor {
                nodes = FileListTreeSupport.sortNodes(view.displayedNodes, using: descriptor)
                sourceIDs = ids
                nodeRevision = view.nodeUpdateRevision
                sortDescriptor = descriptor
                collection.reloadData()
            }

            if navigationIDs != actions.appState.navigationNodeIDs {
                navigationIDs = actions.appState.navigationNodeIDs
                collection.scroll(.zero)
            }

            let selection = Set(nodes.indices.compactMap { index in
                view.selectedEntryIDs.contains(nodes[index].id) ? IndexPath(item: index, section: 0) : nil
            })
            if collection.selectionIndexPaths != selection {
                collection.selectionIndexPaths = selection
            }

            let requestedFocus = focusRequestID.map { $0 != view.focusRequestID } ?? false
            focusRequestID = view.focusRequestID
            if requestedFocus {
                DispatchQueue.main.async { [weak collection] in
                    guard let collection, let window = collection.window else { return }
                    window.makeFirstResponder(collection)
                    if collection.selectionIndexPaths.isEmpty && !self.nodes.isEmpty {
                        collection.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .nearestVerticalEdge)
                        self.selectionChanged(in: collection)
                    }
                }
            }
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            nodes.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
            -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileIconCollectionItem.identifier, for: indexPath)
            if let item = item as? FileIconCollectionItem, let node = node(at: indexPath) {
                item.configure(with: node)
            }
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged(in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
            -> (any NSPasteboardWriting)? {
            node(at: indexPath).flatMap { actions.makePasteboardWriter(for: $0) }
        }

        fileprivate func node(at path: IndexPath) -> FileNode? {
            nodes.indices.contains(path.item) ? nodes[path.item] : nil
        }

        fileprivate func selectionChanged(in collection: NSCollectionView) {
            guard !syncing else { return }
            let ids = Set(collection.selectionIndexPaths.compactMap { node(at: $0)?.id })
            guard ids != actions.appState.selectedEntryIDs else { return }
            actions.appState.selectedEntryIDs = ids
            actions.handleBecameQuickLookOwner()
        }
    }
}

private final class FileIconCollectionView: NSCollectionView, NSUserInterfaceValidations {
    weak var gridCoordinator: FinderGridView.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window,
                  window.attachedSheet == nil, !(window.firstResponder is NSText),
                  gridCoordinator?.actions.appState.isSearchVisible == false else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let clickedPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if event.clickCount == 2, let clickedPath, let node = gridCoordinator?.node(at: clickedPath) {
            gridCoordinator?.actions.openNode(node)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let gridCoordinator else { return nil }
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
              let node = gridCoordinator.node(at: path) else {
            return gridCoordinator.actions.makeContextMenu(for: [])
        }
        let targets = selectionIndexPaths.contains(path)
            ? selectionIndexPaths.sorted().compactMap { gridCoordinator.node(at: $0) }
            : [node]
        window?.makeFirstResponder(self)
        return gridCoordinator.actions.makeContextMenu(for: targets)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        gridCoordinator?.selectionChanged(in: self)
    }

    @objc func copy(_ sender: Any?) {
        gridCoordinator?.actions.handleCopyNames()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !selectionIndexPaths.isEmpty
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let actions = gridCoordinator?.actions else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == [.command, .option], event.charactersIgnoringModifiers?.lowercased() == "c" {
            actions.handleCopyPaths()
            return
        }
        switch event.keyCode {
        case 49 where modifiers.isEmpty:
            actions.handleSpaceKey()
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty, 125 where modifiers == .command:
            actions.handleOpenKey()
        case 126 where modifiers == .command:
            actions.handleNavigateUpKey()
        case 51 where modifiers.isEmpty || modifiers == .command,
             117 where modifiers.isEmpty || modifiers == .command:
            actions.handleDeleteKey()
        case 53 where modifiers.isEmpty:
            actions.handleEscapeKey()
        default:
            super.keyDown(with: event)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookHelper.shared.beginControl(panel: panel, owner: self) { [weak self] in
            self?.gridCoordinator?.actions.handleBecameQuickLookOwner()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookHelper.shared.endControl(panel: panel, owner: self)
    }
}

private final class FileIconCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconCollectionItem")

    private let iconBackground = NSBox()
    private let icon = NSImageView()
    private let nameBackground = NSBox()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let lock = NSImageView()

    override var isSelected: Bool {
        didSet {
            guard isViewLoaded else { return }
            updateSelection()
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            guard isViewLoaded else { return }
            updateSelection()
        }
    }

    override func loadView() {
        view = NSView()
        for box in [iconBackground, nameBackground] {
            box.boxType = .custom
            box.titlePosition = .noTitle
            box.borderWidth = 0
            box.cornerRadius = 6
            box.contentViewMargins = .zero
            view.addSubview(box)
            box.translatesAutoresizingMaskIntoConstraints = false
        }

        icon.imageScaling = .scaleProportionallyUpOrDown
        iconBackground.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        imageView = icon

        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: String(localized: "Encrypted"))
        lock.contentTintColor = .secondaryLabelColor
        iconBackground.addSubview(lock)
        lock.translatesAutoresizingMaskIntoConstraints = false

        name.font = .systemFont(ofSize: 12)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.translatesAutoresizingMaskIntoConstraints = false
        nameBackground.addSubview(name)
        textField = name

        NSLayoutConstraint.activate([
            iconBackground.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            iconBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 74),
            iconBackground.heightAnchor.constraint(equalToConstant: 74),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            lock.widthAnchor.constraint(equalToConstant: 12),
            lock.heightAnchor.constraint(equalToConstant: 12),
            lock.trailingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: -4),
            lock.bottomAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: -4),
            nameBackground.topAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: 2),
            nameBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nameBackground.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
            name.leadingAnchor.constraint(equalTo: nameBackground.leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: nameBackground.trailingAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: nameBackground.topAnchor, constant: 1),
            name.bottomAnchor.constraint(equalTo: nameBackground.bottomAnchor, constant: -1),
        ])
        updateSelection()
    }

    func configure(with node: FileNode) {
        loadViewIfNeeded()
        icon.image = FileIconCache.icon(for: node)
        lock.isHidden = !node.isEncrypted
        name.stringValue = node.name
        view.toolTip = node.name
    }

    private func updateSelection() {
        let showsSelection = highlightState == .forSelection
            || (isSelected && highlightState != .forDeselection)
        iconBackground.fillColor = showsSelection ? NSColor.labelColor.withAlphaComponent(0.12) : .clear
        nameBackground.fillColor = showsSelection ? .selectedContentBackgroundColor : .clear
        name.textColor = showsSelection ? .alternateSelectedControlTextColor : .labelColor
    }
}
