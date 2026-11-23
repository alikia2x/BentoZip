import AppKit
import BentoZipCore
import SwiftUI
import UniformTypeIdentifiers

private extension FileEntry {
    var sortableSize: Int64 {
        isDirectory ? -1 : size
    }

    var sortableType: String {
        if isDirectory { return "文件夹" }
        let ext = url.pathExtension
        return ext.isEmpty ? "文件" : ext.uppercased()
    }

    var sortableModificationDate: Date {
        modificationDate ?? .distantPast
    }
}

struct FileListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        KeyPathComparator(\.name, comparator: .localizedStandard, order: .forward)
    ]
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteEntries: [FileEntry] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
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

    private var emptyOverlayDescription: String {
        if appState.canNavigateUp {
            return "按 Escape 或点击返回上一级"
        }
        if appState.isReadOnlyArchive {
            return "此压缩包为空"
        }
        return "拖放文件到窗口中即可添加"
    }

    private var sortedEntries: [FileEntry] {
        let base = appState.displayedEntries
        if let firstComparator = sortOrder.first, firstComparator.keyPath == \FileEntry.name {
            let folders = base.filter(\.isDirectory).sorted(using: sortOrder)
            let files = base.filter { !$0.isDirectory }.sorted(using: sortOrder)
            return folders + files
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: FileEntry.self, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { entry in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: entry))
                        .foregroundStyle(iconForegroundColor(for: entry))
                        .font(.system(size: 14))
                        .frame(width: 18)

                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if entry.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("此条目已加密")
                    }
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("大小", value: \.sortableSize) { entry in
                if entry.isDirectory {
                    Text("\(entry.children?.count ?? 0) 项")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(Self.byteFormatter.string(fromByteCount: entry.size))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 70, ideal: 95)

            TableColumn("类型", value: \.sortableType) { entry in
                Text(entry.sortableType)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)

            TableColumn("修改日期", value: \.sortableModificationDate) { entry in
                if let date = entry.modificationDate {
                    Text(Self.dateFormatter.string(from: date))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 150)
        } rows: {
            ForEach(sortedEntries) { entry in
                TableRow(entry)
                    .itemProvider {
                        makeItemProvider(for: entry)
                    }
            }
        }
        .overlay {
            if sortedEntries.isEmpty && !appState.isLoading {
                ContentUnavailableView(
                    "此文件夹为空",
                    systemImage: "folder",
                    description: Text(emptyOverlayDescription)
                )
            }
        }
        .onKeyPress(.return) {
            handleReturnKey()
            return .handled
        }
        .onKeyPress(.space) {
            toggleQuickLookForSelection()
            return .handled
        }
        .onKeyPress(.delete) {
            handleDeleteKey()
            return .handled
        }
        .onKeyPress(.escape) {
            if appState.canNavigateUp {
                appState.navigateUp()
            } else {
                appState.clearSelection()
            }
            return .handled
        }
        .onKeyPress(keys: [.upArrow]) { press in
            guard press.modifiers.contains(.command), appState.canNavigateUp else {
                return .ignored
            }
            appState.navigateUp()
            return .handled
        }
        .contextMenu(forSelectionType: UUID.self) { selection in
            let targets = entriesForContextAction(selection: selection)
            if targets.count == 1, let entry = targets.first {
                if entry.isDirectory {
                    Button("打开文件夹") {
                        appState.navigateInto(entry)
                    }
                } else {
                    Button("快速查看") {
                        previewEntries([entry])
                    }
                }
                Divider()
            } else if targets.contains(where: { !$0.isDirectory }) {
                Button("快速查看") {
                    previewEntries(targets)
                }
                Divider()
            }

            if appState.mode == .browseArchive && !targets.isEmpty {
                Button("解压所选...") {
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

            if appState.mode == .compress && !targets.isEmpty {
                Button("从列表移除", role: .destructive) {
                    appState.selectedEntryIDs = Set(targets.map(\.id))
                    appState.removeSelectedEntries()
                }
            } else if appState.isWritableArchive && !targets.isEmpty {
                Button("从压缩包中删除...", role: .destructive) {
                    pendingDeleteEntries = targets
                    showDeleteConfirmation = true
                }
            }

            if targets.count == 1, let entry = targets.first {
                Divider()
                Button(entry.isFromArchive ? "复制归档路径" : "复制路径") {
                    let pathString = entry.archiveRelativePath ?? entry.url.path
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(pathString, forType: .string)
                }
            }
        } primaryAction: { selection in
            handlePrimaryAction(for: selection)
        }
        .confirmationDialog(
            "确定从压缩包中删除所选的 \(pendingDeleteEntries.count) 个项目吗？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
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
            Button("取消", role: .cancel) {
                pendingDeleteEntries = []
            }
        } message: {
            Text("此操作将修改原压缩包文件且不可撤销。")
        }
    }

    // MARK: - Drag & Drop

    private func makeItemProvider(for entry: FileEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name

        let sourceArchiveURL = appState.sourceArchiveURL
        let password = appState.archivePassword

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.item.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                do {
                    let localURL = try await DragDropManager.shared.prepareForDragThrowing(
                        entry,
                        sourceArchiveURL: sourceArchiveURL,
                        password: password
                    )
                    completion(localURL, false, nil)
                } catch {
                    handleEntryExtractionError(error)
                    completion(nil, false, error)
                }
            }
            return nil
        }

        return provider
    }

    // MARK: - Actions

    private func entriesForContextAction(selection: Set<UUID>) -> [FileEntry] {
        let ids = selection.isEmpty ? appState.selectedEntryIDs : selection
        return sortedEntries.filter { ids.contains($0.id) }
    }

    private func handlePrimaryAction(for selection: Set<UUID>) {
        guard selection.count == 1,
              let selectedID = selection.first,
              let entry = sortedEntries.first(where: { $0.id == selectedID }) else {
            return
        }
        if entry.isDirectory {
            appState.navigateInto(entry)
        } else {
            previewEntries([entry])
        }
    }

    private func handleReturnKey() {
        let selected = appState.selectedEntries
        guard selected.count == 1, let entry = selected.first else { return }
        if entry.isDirectory {
            appState.navigateInto(entry)
        } else {
            previewEntries([entry])
        }
    }

    private func toggleQuickLookForSelection() {
        let selected = appState.selectedEntries
        guard !selected.isEmpty else { return }
        QuickLookHelper.shared.togglePreview(
            entries: selected,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        ) { error in
            handleEntryExtractionError(error)
        }
    }

    private func previewEntries(_ entries: [FileEntry]) {
        QuickLookHelper.shared.preview(
            entries: entries,
            sourceArchiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword
        ) { error in
            handleEntryExtractionError(error)
        }
    }

    private func handleEntryExtractionError(_ error: Error) {
        if let bentoError = error as? Bento7zError,
           bentoError == .passwordRequired || bentoError == .wrongPassword {
            if bentoError == .wrongPassword {
                appState.archivePassword = nil
            }
            appState.pendingPasswordArchiveURL = appState.sourceArchiveURL
            appState.isPasswordRetryError = (bentoError == .wrongPassword)
            appState.passwordPromptReason = bentoError.localizedDescription
            appState.needsPasswordPrompt = true
        } else {
            appState.lastError = error.localizedDescription
        }
    }

    private func handleDeleteKey() {
        guard !appState.selectedEntries.isEmpty else { return }
        if appState.mode == .compress {
            appState.removeSelectedEntries()
        } else if appState.isWritableArchive {
            pendingDeleteEntries = appState.selectedEntries
            showDeleteConfirmation = true
        }
    }

    // MARK: - Icons & Colors

    private func iconName(for entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        let ext = entry.url.pathExtension.lowercased()
        switch ext {
        case "zip", "zipx", "7z", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "rar":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "heic", "webp":
            return "photo.fill"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        case "mp4", "mov", "avi", "mkv", "webm":
            return "film.fill"
        case "txt", "md", "rtf", "log":
            return "doc.text.fill"
        case "json", "xml", "yaml", "yml", "plist", "toml":
            return "curlybraces"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h", "hpp", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "dmg", "iso":
            return "opticaldiscdrive"
        case "app":
            return "app.fill"
        default:
            return "doc.fill"
        }
    }

    private func iconForegroundColor(for entry: FileEntry) -> Color {
        if entry.isDirectory { return .cyan }
        let ext = entry.url.pathExtension.lowercased()
        switch ext {
        case "zip", "zipx", "7z", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "rar":
            return .orange
        case "pdf":
            return .red
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "svg", "heic", "webp":
            return .cyan
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return .pink
        case "mp4", "mov", "avi", "mkv", "webm":
            return .purple
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h", "hpp", "sh", "json", "xml", "yaml", "yml":
            return .indigo
        default:
            return .secondary
        }
    }
}

#Preview {
    FileListView()
        .environment(AppState())
        .environment(ProgressState())
}
