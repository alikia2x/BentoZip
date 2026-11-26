import AppKit
import BentoZipCore
import SwiftUI

struct FinderGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

    @State private var lastAnchorNodeID: UUID?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteEntries: [FileEntry] = []

    private let gridColumns = [
        GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 12)
    ]

    private var isBusy: Bool {
        appState.isLoading || progressState.isOperationInProgress
    }

    private var sortedItems: [FileNode] {
        let prefs = appState.preferencesManager?.loadPreferences()
        let descriptor = NSSortDescriptor(
            key: prefs?.sortColumnKey ?? "name",
            ascending: prefs?.sortAscending ?? true
        )
        return FileListTreeSupport.sortNodes(appState.displayedNodes, using: descriptor)
    }

    var body: some View {
        let items = sortedItems

        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(items) { node in
                    gridTile(for: node, in: items)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            Color(nsColor: .controlBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.clearSelection()
                }
        )
        .contextMenu {
            if appState.isWritableArchive {
                Button("New Folder…") {
                    uiState.showNewFolderSheet = true
                }
                .disabled(isBusy)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            handleSpaceKey()
            return .handled
        }
        .onKeyPress(.return) {
            handleReturnKey()
            return .handled
        }
        .onKeyPress(.escape) {
            handleEscapeKey()
            return .handled
        }
        .onKeyPress(.delete) {
            handleDeleteKey()
            return .handled
        }
        .onDeleteCommand {
            handleDeleteKey()
        }
        .confirmationDialog(
            Text("Delete \(pendingDeleteEntries.count) selected items from archive?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let entriesToDelete = pendingDeleteEntries
                pendingDeleteEntries = []
                Task {
                    await appState.coordinator.removeEntries(
                        appState: appState,
                        entries: entriesToDelete,
                        progressState: progressState
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteEntries = []
            }
        } message: {
            Text("This modifies the archive and cannot be undone.")
        }
    }

    @ViewBuilder
    private func gridTile(for node: FileNode, in items: [FileNode]) -> some View {
        let isSelected = appState.selectedEntryIDs.contains(node.id)

        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: FileIconCache.icon(for: node))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 54, height: 54)

                if node.isEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .background(.regularMaterial, in: Circle())
                        .offset(x: 2, y: 2)
                }
            }
            .frame(width: 76, height: 68)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.11) : Color.clear)
            )

            Text(node.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            openNode(node)
        }
        .onTapGesture(count: 1) {
            selectNode(node, in: items)
        }
        .contextMenu {
            contextMenuItems(for: contextTargetNodes(for: node))
        }
    }

    // MARK: - Selection & Actions

    private func selectNode(_ node: FileNode, in items: [FileNode]) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.command) {
            if appState.selectedEntryIDs.contains(node.id) {
                appState.selectedEntryIDs.remove(node.id)
            } else {
                appState.selectedEntryIDs.insert(node.id)
            }
            lastAnchorNodeID = node.id
        } else if modifiers.contains(.shift),
                  let anchorID = lastAnchorNodeID,
                  let startIdx = items.firstIndex(where: { $0.id == anchorID }),
                  let endIdx = items.firstIndex(where: { $0.id == node.id }) {
            let lower = min(startIdx, endIdx)
            let upper = max(startIdx, endIdx)
            appState.selectedEntryIDs = Set(items[lower...upper].map(\.id))
        } else {
            appState.selectedEntryIDs = [node.id]
            lastAnchorNodeID = node.id
        }

        if QuickLookHelper.shared.isVisible {
            previewNodes(appState.selectedNodes)
        }
    }

    private func contextTargetNodes(for clickedNode: FileNode) -> [FileNode] {
        if appState.selectedEntryIDs.contains(clickedNode.id) {
            return appState.selectedNodes
        }
        return [clickedNode]
    }

    private func openNode(_ node: FileNode) {
        if node.isDirectory {
            appState.navigateInto(node)
            return
        }
        let isArchiveItem = !node.url.path.hasPrefix("/")
            ? (!node.name.isEmpty && FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "/tmp/\(node.name)")) != nil)
            : FormatDetector.isArchiveFile(node.url)
        if appState.mode == .browseArchive, isArchiveItem {
            guard !isBusy else { return }
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
        Task {
            await appState.coordinator.extractEntryForOpen(
                entry,
                archiveURL: appState.sourceArchiveURL,
                password: appState.archivePassword,
                appState: appState
            )
        }
    }

    private func previewNodes(_ nodes: [FileNode]) {
        let previewEntries = nodes
            .filter { !$0.isDirectory || !$0.isFromArchive }
            .map { $0.toFileEntry() }
        QuickLookHelper.shared.preview(
            nodes: nodes,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword,
            encoding: appState.selectedEncoding.iconvName
        ) { error in
            FileListTreeSupport.handleExtractionError(
                error,
                appState: appState,
                retryAction: previewEntries.isEmpty ? nil : .preview(previewEntries)
            )
        }
    }

    private func handleSpaceKey() {
        if QuickLookHelper.shared.isVisible {
            QuickLookHelper.shared.closeIfVisible()
            return
        }
        let targets = appState.selectedNodes
        guard !targets.isEmpty else { return }
        previewNodes(targets)
    }

    private func handleReturnKey() {
        let targets = appState.selectedNodes
        guard targets.count == 1, let node = targets.first else { return }
        openNode(node)
    }

    private func handleEscapeKey() {
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

    private func handleDeleteKey() {
        guard !isBusy else { return }
        let targets = appState.selectedNodes
        guard !targets.isEmpty else { return }
        if appState.mode == .compress {
            appState.removeNodes(targets)
        } else if appState.isWritableArchive {
            pendingDeleteEntries = targets.map { $0.toFileEntry() }
            showDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private func contextMenuItems(for targets: [FileNode]) -> some View {
        if targets.count == 1, let node = targets.first {
            Button("Open") {
                openNode(node)
            }
            if !node.isDirectory || !node.isFromArchive {
                Button("Quick Look") {
                    previewNodes([node])
                }
            }
        } else if targets.contains(where: { !$0.isDirectory || !$0.isFromArchive }) {
            Button("Quick Look") {
                previewNodes(targets)
            }
        }

        if appState.mode == .browseArchive {
            Divider()
            Button("Extract Selected Here") {
                let entries = targets.map { $0.toFileEntry() }
                Task {
                    await appState.coordinator.extract(
                        appState: appState,
                        progressState: progressState,
                        entries: entries,
                        chooseDestination: false
                    )
                }
            }
            .disabled(isBusy)

            Button("Extract Selected…") {
                let entries = targets.map { $0.toFileEntry() }
                Task {
                    await appState.coordinator.extract(
                        appState: appState,
                        progressState: progressState,
                        entries: entries,
                        chooseDestination: true
                    )
                }
            }
            .disabled(isBusy)
        }

        if appState.mode == .compress {
            Divider()
            if targets.count == 1, let first = targets.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([first.url])
                }
            }
            Button("Remove", role: .destructive) {
                appState.removeNodes(targets)
            }
            .disabled(isBusy)
        } else if appState.isWritableArchive {
            Divider()
            Button("New Folder…") {
                uiState.showNewFolderSheet = true
            }
            .disabled(isBusy)

            if targets.count == 1, let first = targets.first {
                Button("Rename…") {
                    uiState.renameTargetEntry = first.toFileEntry()
                }
                .disabled(isBusy)
            }

            Button("Delete", role: .destructive) {
                pendingDeleteEntries = targets.map { $0.toFileEntry() }
                showDeleteConfirmation = true
            }
            .disabled(isBusy)
        }

        Divider()
        Button(targets.count == 1 ? "Copy Name" : "Copy Names") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(targets.map(\.name).joined(separator: "\n"), forType: .string)
        }
        Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(
                targets.map { $0.archiveRelativePath ?? $0.url.path }.joined(separator: "\n"),
                forType: .string
            )
        }
    }
}
