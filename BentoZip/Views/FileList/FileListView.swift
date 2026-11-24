import AppKit
import BentoZipCore
import SwiftUI

struct FileListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\.name, comparator: .localizedStandard, order: .forward)
    ]
    @State private var sortedEntries: [FileEntry] = []
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteEntries: [FileEntry] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { appState.selectedEntryIDs },
            set: { appState.selectedEntryIDs = $0 }
        )
    }

    var body: some View {
        tableView
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .onAppear { rebuildSortedEntries() }
            .onChange(of: appState.displayedEntries) { _, _ in rebuildSortedEntries() }
            .onChange(of: sortOrder) { _, _ in rebuildSortedEntries() }
            .overlay {
                if sortedEntries.isEmpty && !appState.isLoading {
                    Text("Empty Folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .onKeyPress(.return) { handleOpenSelection(); return .handled }
            .onKeyPress(.space) { toggleQuickLook(); return .handled }
            .onKeyPress(.delete) { handleDeleteSelection(); return .handled }
            .onKeyPress(.escape) {
                if appState.canNavigateUp { appState.navigateUp() } else { appState.clearSelection() }
                return .handled
            }
            .onKeyPress(keys: [.upArrow]) { press in
                guard press.modifiers.contains(.command), appState.canNavigateUp else { return .ignored }
                appState.navigateUp()
                return .handled
            }
            .onKeyPress(keys: [.downArrow]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                handleOpenSelection()
                return .handled
            }
            .contextMenu(forSelectionType: UUID.self) { selection in
                contextMenuItems(for: selection)
            } primaryAction: { selection in
                handlePrimaryAction(for: selection)
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
                            progressState: progressState,
                            openWindow: openWindow
                        )
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeleteEntries = [] }
            } message: {
                Text("This modifies the archive and cannot be undone.")
            }
    }

    // MARK: - Finder Table

    @ViewBuilder
    private var tableView: some View {
        if appState.mode == .browseArchive {
            Table(of: FileEntry.self, selection: selectionBinding, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { nameCell(for: $0) }
                    .width(min: 140, ideal: 200)
                TableColumn("Date Modified", value: \.sortableModificationDate) { dateCell(for: $0) }
                    .width(min: 108, ideal: 132)
                TableColumn("Size", value: \.sortableSize) { sizeCell(for: $0) }
                    .width(min: 62, ideal: 74)
                TableColumn("Packed", value: \.sortablePackedSize) { packedCell(for: $0) }
                    .width(min: 62, ideal: 74)
                TableColumn("Kind") { kindCell(for: $0) }
                    .width(min: 68, ideal: 92)
            } rows: {
                tableRows
            }
        } else {
            Table(of: FileEntry.self, selection: selectionBinding, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { nameCell(for: $0) }
                    .width(min: 150, ideal: 215)
                TableColumn("Date Modified", value: \.sortableModificationDate) { dateCell(for: $0) }
                    .width(min: 112, ideal: 138)
                TableColumn("Size", value: \.sortableSize) { sizeCell(for: $0) }
                    .width(min: 64, ideal: 78)
                TableColumn("Kind") { kindCell(for: $0) }
                    .width(min: 72, ideal: 96)
            } rows: {
                tableRows
            }
        }
    }

    // MARK: - Finder Columns

    private func nameCell(for entry: FileEntry) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: FileIconCache.icon(for: entry))
                .resizable()
                .frame(width: 16, height: 16)

            Text(entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            if entry.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dateCell(for entry: FileEntry) -> some View {
        Group {
            if let date = entry.modificationDate {
                Text(Self.dateFormatter.string(from: date))
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    private func sizeCell(for entry: FileEntry) -> some View {
        let text: String = if entry.isDirectory {
            entry.size > 0 ? Self.byteFormatter.string(fromByteCount: entry.size) : "--"
        } else {
            Self.byteFormatter.string(fromByteCount: entry.size)
        }
        return Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func packedCell(for entry: FileEntry) -> some View {
        Group {
            if let packed = entry.packedSize, !entry.isDirectory, packed > 0 {
                Text(Self.byteFormatter.string(fromByteCount: packed))
                    .foregroundStyle(.secondary)
            } else {
                Text("--")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func kindCell(for entry: FileEntry) -> some View {
        Text(FileKindCache.localizedKind(for: entry))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: - Finder Outline Disclosure Rows

    @TableRowBuilder<FileEntry>
    private var tableRows: some TableRowContent<FileEntry> {
        ForEach(sortedEntries) { entry in
            outlineRowLevel0(entry)
        }
    }

    @TableRowBuilder<FileEntry>
    private func outlineRowLevel0(_ entry: FileEntry) -> some TableRowContent<FileEntry> {
        if entry.isDirectory, let children = entry.children, !children.isEmpty {
            DisclosureTableRow(entry) {
                ForEach(FileListTreeSupport.sorted(children, using: sortOrder)) { child in
                    outlineRowLevel1(child)
                }
            }
        } else {
            TableRow(entry)
                .itemProvider { FileListTreeSupport.makeItemProvider(for: entry, appState: appState) }
        }
    }

    @TableRowBuilder<FileEntry>
    private func outlineRowLevel1(_ entry: FileEntry) -> some TableRowContent<FileEntry> {
        if entry.isDirectory, let children = entry.children, !children.isEmpty {
            DisclosureTableRow(entry) {
                ForEach(FileListTreeSupport.sorted(children, using: sortOrder)) { child in
                    outlineRowLevel2(child)
                }
            }
        } else {
            TableRow(entry)
                .itemProvider { FileListTreeSupport.makeItemProvider(for: entry, appState: appState) }
        }
    }

    @TableRowBuilder<FileEntry>
    private func outlineRowLevel2(_ entry: FileEntry) -> some TableRowContent<FileEntry> {
        if entry.isDirectory, let children = entry.children, !children.isEmpty {
            DisclosureTableRow(entry) {
                ForEach(FileListTreeSupport.sorted(children, using: sortOrder)) { child in
                    TableRow(child)
                        .itemProvider { FileListTreeSupport.makeItemProvider(for: child, appState: appState) }
                }
            }
        } else {
            TableRow(entry)
                .itemProvider { FileListTreeSupport.makeItemProvider(for: entry, appState: appState) }
        }
    }

    // MARK: - Context Menu & Actions

    @ViewBuilder
    private func contextMenuItems(for selection: Set<UUID>) -> some View {
        let ids = selection.isEmpty ? appState.selectedEntryIDs : selection
        let targets = FileListTreeSupport.findEntries(matching: ids, in: sortedEntries)

        if targets.count == 1, let entry = targets.first {
            if entry.isDirectory {
                Button("Open") { appState.navigateInto(entry) }
            } else {
                Button("Quick Look") { previewEntries([entry]) }
            }
            Divider()
        } else if targets.contains(where: { !$0.isDirectory }) {
            Button("Quick Look") { previewEntries(targets) }
            Divider()
        }

        if appState.mode == .browseArchive && !targets.isEmpty {
            Button("Extract Selected…") {
                Task {
                    await appState.coordinator.extract(
                        appState: appState,
                        progressState: progressState,
                        entries: targets,
                        chooseDestination: true,
                        openWindow: openWindow
                    )
                }
            }
        }

        if appState.mode == .compress && targets.count == 1, let entry = targets.first {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }

        if appState.mode == .compress && !targets.isEmpty {
            Button("Remove", role: .destructive) {
                appState.selectedEntryIDs = Set(targets.map(\.id))
                appState.removeSelectedEntries()
            }
        } else if appState.isWritableArchive && !targets.isEmpty {
            Button("Delete…", role: .destructive) {
                pendingDeleteEntries = targets
                showDeleteConfirmation = true
            }
        }

        if targets.count == 1, let entry = targets.first {
            Divider()
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.archiveRelativePath ?? entry.url.path, forType: .string)
            }
        }
    }

    private func rebuildSortedEntries() {
        sortedEntries = FileListTreeSupport.sorted(appState.displayedEntries, using: sortOrder)
    }

    private func handlePrimaryAction(for selection: Set<UUID>) {
        guard selection.count == 1,
              let selectedID = selection.first,
              let entry = FileListTreeSupport.findEntries(matching: [selectedID], in: sortedEntries).first else {
            return
        }
        if entry.isDirectory { appState.navigateInto(entry) } else { previewEntries([entry]) }
    }

    private func handleOpenSelection() {
        let selected = FileListTreeSupport.findEntries(matching: appState.selectedEntryIDs, in: sortedEntries)
        guard selected.count == 1, let entry = selected.first else { return }
        if entry.isDirectory { appState.navigateInto(entry) } else { previewEntries([entry]) }
    }

    private func toggleQuickLook() {
        let selected = FileListTreeSupport.findEntries(matching: appState.selectedEntryIDs, in: sortedEntries)
        guard !selected.isEmpty else { return }
        QuickLookHelper.shared.togglePreview(
            entries: selected,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        ) { error in
            FileListTreeSupport.handleExtractionError(error, appState: appState)
        }
    }

    private func previewEntries(_ entries: [FileEntry]) {
        QuickLookHelper.shared.preview(
            entries: entries,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        ) { error in
            FileListTreeSupport.handleExtractionError(error, appState: appState)
        }
    }

    private func handleDeleteSelection() {
        let selected = FileListTreeSupport.findEntries(matching: appState.selectedEntryIDs, in: sortedEntries)
        guard !selected.isEmpty else { return }
        if appState.mode == .compress {
            appState.removeSelectedEntries()
        } else if appState.isWritableArchive {
            pendingDeleteEntries = selected
            showDeleteConfirmation = true
        }
    }
}
