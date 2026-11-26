import AppKit
import BentoZipCore
import SwiftUI

struct ArchiveInfoInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme

    @State private var checksumsByNodeID: [UUID: FileChecksums] = [:]
    @State private var computingChecksumNodeID: UUID?

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color(nsColor: .labelColor)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.60) : Color(nsColor: .secondaryLabelColor)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var isBusy: Bool {
        appState.isLoading || progressState.isOperationInProgress
    }

    private var canUpdatePassword: Bool {
        guard appState.isWritableArchive,
              let archiveURL = appState.sourceArchiveURL,
              let format = FormatDetector.detectFormat(of: archiveURL) else {
            return false
        }
        return format.supportsPassword
    }

    private var encodingBinding: Binding<FilenameEncodingOption> {
        Binding(
            get: { appState.selectedEncoding },
            set: { newValue in
                guard newValue != appState.selectedEncoding else { return }
                Task {
                    await appState.coordinator.reloadWithEncoding(newValue, appState: appState)
                }
            }
        )
    }

    var body: some View {
        let selectedNodes = appState.selectedNodes

        InspectorScrollContainer {
            if selectedNodes.isEmpty {
                archiveOverviewSections
            } else if selectedNodes.count == 1, let node = selectedNodes.first {
                singleSelectionSections(for: node)
            } else {
                multiSelectionSections(for: selectedNodes)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(selectedNodes: selectedNodes)
        }
        .onChange(of: appState.selectedEntryIDs) { _, newIDs in
            checksumsByNodeID = checksumsByNodeID.filter { newIDs.contains($0.key) }
            if let activeID = computingChecksumNodeID, !newIDs.contains(activeID) {
                computingChecksumNodeID = nil
            }
        }
        .onChange(of: appState.sourceArchiveURL) { _, _ in
            checksumsByNodeID.removeAll()
            computingChecksumNodeID = nil
        }
        .onChange(of: appState.treeStructureRevision) { _, _ in
            checksumsByNodeID.removeAll()
        }
    }

    // MARK: - 0 Items Selected (Archive Info)

    @ViewBuilder
    private var archiveOverviewSections: some View {
        let totalCount = appState.totalEntryCount
        let uncompressedStr = Self.byteFormatter.string(fromByteCount: appState.totalSize)

        if let archiveURL = appState.sourceArchiveURL {
            InspectorCard {
                HStack(spacing: 10) {
                    Image(nsImage: FileIconCache.icon(forFileAt: archiveURL.path))
                        .resizable()
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(archiveURL.lastPathComponent)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text(archiveMetaSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }
        }

        InspectorCard("Info") {
            InspectorRow("Items") {
                Text(String(localized: "\(totalCount) items"))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }

            InspectorRowDivider()

            InspectorRow("Size") {
                Text(uncompressedStr)
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }

            if let packed = appState.totalPackedSize, packed > 0 {
                InspectorRowDivider()

                InspectorRow("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: packed))
                        .monospacedDigit()
                        .foregroundStyle(secondaryTextColor)
                }

                if appState.totalSize > 0 && packed <= appState.totalSize {
                    let saved = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
                    InspectorRowDivider()

                    InspectorRow("Saved Ratio") {
                        Text("\(saved)%")
                            .monospacedDigit()
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }

            if appState.isArchiveEncrypted {
                InspectorRowDivider()

                InspectorRow("Encryption") {
                    Text("Encrypted")
                        .foregroundStyle(secondaryTextColor)
                }
            }

            if canUpdatePassword {
                InspectorRowDivider()

                InspectorRow("Password") {
                    Button(appState.isArchiveEncrypted ? "Change…" : "Set…") {
                        uiState.showUpdatePasswordSheet = true
                    }
                    .buttonStyle(InspectorPillButtonStyle(compact: true))
                    .disabled(isBusy)
                }
            }

            InspectorRowDivider()

            InspectorRow("Encoding") {
                Menu {
                    ForEach(FilenameEncodingOption.allCases) { option in
                        Button {
                            guard option != appState.selectedEncoding else { return }
                            Task {
                                await appState.coordinator.reloadWithEncoding(option, appState: appState)
                            }
                        } label: {
                            if appState.selectedEncoding == option {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    InspectorMenuLabel(title: appState.selectedEncoding.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isBusy)
            }

            InspectorRowDivider()

            InspectorRow("Integrity") {
                Button("Verify") {
                    Task {
                        await appState.coordinator.testArchive(
                            appState: appState,
                            progressState: progressState
                        )
                    }
                }
                .buttonStyle(InspectorPillButtonStyle(compact: true))
                .disabled(isBusy)
            }
        }

        if let comment = appState.archiveComment, !comment.isEmpty {
            InspectorCard("Comment") {
                Text(comment)
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 1 Item Selected

    @ViewBuilder
    private func singleSelectionSections(for node: FileNode) -> some View {
        let kind = FileKindCache.localizedKind(for: node)
        let location = parentLocation(for: node)

        InspectorCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: FileIconCache.icon(for: node))
                        .resizable()
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Text(kind)
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryTextColor)
                    }
                }

                if !node.isDirectory {
                    HStack(spacing: 6) {
                        Button {
                            let entry = node.toFileEntry()
                            QuickLookHelper.shared.preview(
                                nodes: [node],
                                sourceArchiveURL: appState.sourceArchiveURL,
                                password: appState.archivePassword,
                                encoding: appState.selectedEncoding.iconvName
                            ) { error in
                                FileListTreeSupport.handleExtractionError(
                                    error,
                                    appState: appState,
                                    retryAction: .preview([entry])
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "eye")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Quick Look")
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorPillButtonStyle(compact: true))
                        .disabled(isBusy)

                        Button {
                            let entry = node.toFileEntry()
                            Task {
                                await appState.coordinator.extractEntryForOpen(
                                    entry,
                                    archiveURL: appState.sourceArchiveURL,
                                    password: appState.archivePassword,
                                    appState: appState
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Open")
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorPillButtonStyle(compact: true))
                        .disabled(isBusy)
                    }
                }
            }
        }

        if !node.isDirectory,
           InlinePreviewHelper.isImageFile(node.name) ||
           (InlinePreviewHelper.isTextPreviewable(node.name) && node.size <= 256 * 1024) {
            SingleEntryPreviewSection(node: node)
        }

        InspectorCard("Info") {
            if let location {
                InspectorRow("Location") {
                    Text(location)
                        .foregroundStyle(secondaryTextColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                InspectorRowDivider()
            }

            InspectorRow("Size") {
                let effectiveSize = node.isDirectory ? node.archiveTotalSize : node.size
                if node.isDirectory && effectiveSize <= 0 {
                    Text("--")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Self.byteFormatter.string(fromByteCount: effectiveSize))
                        .monospacedDigit()
                        .foregroundStyle(secondaryTextColor)
                }
            }

            if !node.isDirectory, let packed = node.packedSize, packed > 0 {
                InspectorRowDivider()

                InspectorRow("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: packed))
                        .monospacedDigit()
                        .foregroundStyle(secondaryTextColor)
                }

                if node.size > 0 && packed <= node.size {
                    let saved = Int(((Double(node.size - packed) / Double(node.size)) * 100).rounded())
                    InspectorRowDivider()

                    InspectorRow("Saved Ratio") {
                        Text("\(saved)%")
                            .monospacedDigit()
                            .foregroundStyle(secondaryTextColor)
                    }
                }
            }

            if let modified = node.modificationDate {
                InspectorRowDivider()

                InspectorRow("Modified") {
                    Text(FileListFormatters.dateFormatter.string(from: modified))
                        .monospacedDigit()
                        .foregroundStyle(secondaryTextColor)
                }
            }

            if node.isEncrypted {
                InspectorRowDivider()

                InspectorRow("Encryption") {
                    Text("Encrypted")
                        .foregroundStyle(secondaryTextColor)
                }
            }

            if let crc = node.crc {
                InspectorRowDivider()

                InspectorRow("CRC32") {
                    Text(String(format: "%08X", crc))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(secondaryTextColor)
                        .textSelection(.enabled)
                }
            }

            if !node.isDirectory {
                InspectorRowDivider()

                if let checksums = checksumsByNodeID[node.id] {
                    checksumRow(title: "SHA-256", value: checksums.sha256)
                    InspectorRowDivider()
                    checksumRow(title: "MD5", value: checksums.md5)
                } else {
                    InspectorRow("Checksums") {
                        if computingChecksumNodeID == node.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Calculate") {
                                calculateChecksums(for: node)
                            }
                            .buttonStyle(InspectorPillButtonStyle(compact: true))
                            .disabled(isBusy || computingChecksumNodeID != nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - >1 Items Selected

    @ViewBuilder
    private func multiSelectionSections(for selectedNodes: [FileNode]) -> some View {
        let totals = combinedSelectionTotals(for: selectedNodes)

        InspectorCard {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 22))
                    .foregroundStyle(secondaryTextColor)
                    .frame(width: 32, height: 32)

                Text(String(localized: "\(selectedNodes.count) items selected"))
                    .font(.system(size: 12.5, weight: .semibold))
            }
        }

        InspectorCard("Info") {
            InspectorRow("Size") {
                Text(Self.byteFormatter.string(fromByteCount: totals.uncompressed))
                    .monospacedDigit()
                    .foregroundStyle(secondaryTextColor)
            }

            if totals.packed > 0 {
                InspectorRowDivider()

                InspectorRow("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: totals.packed))
                        .monospacedDigit()
                        .foregroundStyle(secondaryTextColor)
                }
            }
        }
    }

    // MARK: - Adaptive Bottom Bar

    private func bottomBar(selectedNodes: [FileNode]) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if selectedNodes.isEmpty {
                    Button("Extract To…") {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: true
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isBusy)

                    Spacer(minLength: 8)

                    Button {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: false
                            )
                        }
                    } label: {
                        Text("Extract")
                            .frame(minWidth: 68)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isBusy)
                } else {
                    Button("Extract All") {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: false
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isBusy)

                    Spacer(minLength: 8)

                    Button {
                        let entries = selectedNodes.map { $0.toFileEntry() }
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                entries: entries,
                                chooseDestination: true
                            )
                        }
                    } label: {
                        Text(String(localized: "Extract (\(selectedNodes.count))"))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Extract Selected…")
                    .disabled(isBusy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func checksumRow(title: LocalizedStringKey, value: String) -> some View {
        InspectorRow(title) {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(secondaryTextColor)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
    }

    private func calculateChecksums(for node: FileNode) {
        let nodeID = node.id
        let entry = node.toFileEntry()
        computingChecksumNodeID = nodeID
        Task {
            do {
                let result = try await appState.coordinator.computeChecksums(
                    for: entry,
                    appState: appState
                )
                if appState.selectedEntryIDs.contains(nodeID) {
                    checksumsByNodeID[nodeID] = result
                }
            } catch is CancellationError {
                // Ignored on cancellation
            } catch {
                FileListTreeSupport.handleExtractionError(
                    error,
                    appState: appState,
                    retryAction: .preview([entry])
                )
            }
            if computingChecksumNodeID == nodeID {
                computingChecksumNodeID = nil
            }
        }
    }

    private func parentLocation(for node: FileNode) -> String? {
        guard let rawPath = node.archiveRelativePath else { return nil }
        var normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        while normalized.hasPrefix("/") { normalized.removeFirst() }
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let parent = (normalized as NSString).deletingLastPathComponent
        return (parent.isEmpty || parent == ".") ? nil : parent
    }

    private var archiveMetaSummary: String {
        let format = appState.archiveFormatName ?? String(localized: "Archive")
        return appState.isReadOnlyArchive
            ? String(localized: "\(format) (Read-Only)")
            : format
    }

    private func combinedSelectionTotals(for nodes: [FileNode]) -> (uncompressed: Int64, packed: Int64) {
        let selectedIDs = appState.selectedEntryIDs
        var uncompressed: Int64 = 0
        var packed: Int64 = 0

        for node in nodes {
            var ancestor = node.parent
            var hasSelectedAncestor = false
            while let current = ancestor {
                if selectedIDs.contains(current.id) {
                    hasSelectedAncestor = true
                    break
                }
                ancestor = current.parent
            }
            if hasSelectedAncestor { continue }

            uncompressed += node.archiveTotalSize
            packed += packedSubtreeSize(of: node)
        }

        return (uncompressed, packed)
    }

    private func packedSubtreeSize(of node: FileNode) -> Int64 {
        if !node.isDirectory {
            return max(0, node.packedSize ?? 0)
        }
        guard let children = node.children else { return 0 }
        return children.reduce(Int64(0)) { $0 + packedSubtreeSize(of: $1) }
    }
}

private struct SingleEntryPreviewSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WorkspaceUIState.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme

    let node: FileNode

    @State private var previewImage: NSImage?
    @State private var previewText: String?
    @State private var isLoading: Bool = false

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.60) : Color(nsColor: .secondaryLabelColor)
    }

    private struct PreviewKey: Equatable {
        let nodeID: UUID
        let archiveURL: URL?
        let password: String?
        let encoding: FilenameEncodingOption
    }

    private var isImage: Bool {
        InlinePreviewHelper.isImageFile(node.name)
    }

    private var taskKey: PreviewKey {
        PreviewKey(
            nodeID: node.id,
            archiveURL: appState.sourceArchiveURL,
            password: appState.archivePassword,
            encoding: appState.selectedEncoding
        )
    }

    var body: some View {
        InspectorCard("Preview") {
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .frame(height: 64)
                } else if isImage, let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    if !appState.galleryImageNodes.isEmpty {
                        Button {
                            uiState.galleryInitialNodeID = node.id
                            uiState.showImageGallery = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("Open Gallery")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorPillButtonStyle())
                    }
                } else if let previewText {
                    ScrollView {
                        Text(previewText.isEmpty ? String(localized: "(Empty file)") : previewText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(secondaryTextColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                } else {
                    Text("Preview unavailable")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task(id: taskKey) {
            await loadPreview()
        }
    }

    @MainActor
    private func loadPreview() async {
        previewImage = nil
        previewText = nil
        isLoading = true
        defer { isLoading = false }

        let targetURL: URL
        if !node.isFromArchive {
            targetURL = node.url
        } else {
            guard let archiveURL = appState.sourceArchiveURL else { return }
            do {
                guard let extracted = try await DragDropManager.shared.prepareForDragThrowing(
                    node.toFileEntry(),
                    sourceArchiveURL: archiveURL,
                    password: appState.archivePassword,
                    encoding: appState.selectedEncoding.iconvName
                ) else {
                    return
                }
                targetURL = extracted
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        if isImage {
            let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let data = try? Data(contentsOf: targetURL) else { return nil }
                return NSImage(data: data)
            }.value
            guard !Task.isCancelled else { return }
            previewImage = loaded
        } else {
            let snippet = await InlinePreviewHelper.loadTextSnippet(from: targetURL, maxBytes: 16_384)
            guard !Task.isCancelled else { return }
            previewText = snippet
        }
    }
}
