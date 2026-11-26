import AppKit
import BentoZipCore
import SwiftUI

struct ArchiveInfoInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var isBusy: Bool {
        appState.isLoading || progressState.isOperationInProgress
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

        Form {
            if selectedNodes.isEmpty {
                archiveOverviewSections
            } else if selectedNodes.count == 1, let node = selectedNodes.first {
                singleSelectionSections(for: node)
            } else {
                multiSelectionSections(for: selectedNodes)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar(selectedNodes: selectedNodes)
        }
    }

    // MARK: - 0 Items Selected (Archive Info)

    @ViewBuilder
    private var archiveOverviewSections: some View {
        let totalCount = appState.totalEntryCount
        let uncompressedStr = Self.byteFormatter.string(fromByteCount: appState.totalSize)

        if let archiveURL = appState.sourceArchiveURL {
            Section {
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
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }

        Section("Info") {
            LabeledContent("Items") {
                Text(String(localized: "\(totalCount) items"))
                    .monospacedDigit()
            }

            LabeledContent("Size") {
                Text(uncompressedStr)
                    .monospacedDigit()
            }

            if let packed = appState.totalPackedSize, packed > 0 {
                LabeledContent("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: packed))
                        .monospacedDigit()
                }

                if appState.totalSize > 0 && packed <= appState.totalSize {
                    let saved = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
                    LabeledContent("Saved Ratio") {
                        Text("\(saved)%")
                            .monospacedDigit()
                    }
                }
            }

            if appState.isArchiveEncrypted {
                LabeledContent("Encryption") {
                    Text("Encrypted")
                }
            }

            Picker("Encoding", selection: encodingBinding) {
                ForEach(FilenameEncodingOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .disabled(isBusy)

            LabeledContent("Integrity") {
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
    }

    // MARK: - 1 Item Selected

    @ViewBuilder
    private func singleSelectionSections(for node: FileNode) -> some View {
        let kind = FileKindCache.localizedKind(for: node)
        let location = parentLocation(for: node)

        Section {
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
                            .foregroundStyle(.secondary)
                    }
                }

                if !node.isDirectory {
                    HStack(spacing: 8) {
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
                            HStack(spacing: 5) {
                                Image(systemName: "eye")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(Color(nsColor: .labelColor))
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("Quick Look")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorPillButtonStyle())
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
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.forward.app")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(Color(nsColor: .labelColor))
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("Open")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(InspectorPillButtonStyle())
                        .disabled(isBusy)
                    }
                }
            }
            .padding(.vertical, 2)
        }

        Section("Info") {
            if let location {
                LabeledContent("Location") {
                    Text(location)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Size") {
                let effectiveSize = node.isDirectory ? node.archiveTotalSize : node.size
                if node.isDirectory && effectiveSize <= 0 {
                    Text("--")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(Self.byteFormatter.string(fromByteCount: effectiveSize))
                        .monospacedDigit()
                }
            }

            if !node.isDirectory, let packed = node.packedSize, packed > 0 {
                LabeledContent("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: packed))
                        .monospacedDigit()
                }

                if node.size > 0 && packed <= node.size {
                    let saved = Int(((Double(node.size - packed) / Double(node.size)) * 100).rounded())
                    LabeledContent("Saved Ratio") {
                        Text("\(saved)%")
                            .monospacedDigit()
                    }
                }
            }

            if let modified = node.modificationDate {
                LabeledContent("Modified") {
                    Text(FileListFormatters.dateFormatter.string(from: modified))
                        .monospacedDigit()
                }
            }

            if node.isEncrypted {
                LabeledContent("Encryption") {
                    Text("Encrypted")
                }
            }

            if let crc = node.crc {
                LabeledContent("CRC32") {
                    Text(String(format: "%08X", crc))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - >1 Items Selected

    @ViewBuilder
    private func multiSelectionSections(for selectedNodes: [FileNode]) -> some View {
        let totals = combinedSelectionTotals(for: selectedNodes)

        Section {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                Text(String(localized: "\(selectedNodes.count) items selected"))
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .padding(.vertical, 2)
        }

        Section("Info") {
            LabeledContent("Size") {
                Text(Self.byteFormatter.string(fromByteCount: totals.uncompressed))
                    .monospacedDigit()
            }

            if totals.packed > 0 {
                LabeledContent("Packed") {
                    Text(Self.byteFormatter.string(fromByteCount: totals.packed))
                        .monospacedDigit()
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

private struct InspectorPillButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12, weight: .medium))
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .padding(.horizontal, compact ? 10 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
