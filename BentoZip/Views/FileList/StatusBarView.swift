import SwiftUI
import BentoZipCore

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var formattedTotalSize: String {
        Self.byteFormatter.string(fromByteCount: appState.totalSize)
    }

    private var selectedEntriesSize: Int64 {
        appState.selectedEntries.reduce(0) { partial, entry in
            partial + entryTotalSize(entry)
        }
    }

    private var formattedPackedInfo: String? {
        guard appState.mode == .browseArchive,
              let packed = appState.totalPackedSize,
              packed > 0 else {
            return nil
        }
        let packedStr = Self.byteFormatter.string(fromByteCount: packed)
        if appState.totalSize > 0 && packed <= appState.totalSize {
            let ratio = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
            return "压缩后 \(packedStr) · 节省 \(ratio)%"
        }
        return "压缩后 \(packedStr)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 10) {
                Text("共 \(appState.displayedEntries.count) 项")
                    .monospacedDigit()

                if !appState.selectedEntryIDs.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("已选 \(appState.selectedEntryIDs.count) 项 (\(Self.byteFormatter.string(fromByteCount: selectedEntriesSize)))")
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }

                Text("·")
                    .foregroundStyle(.tertiary)

                Text("总大小 \(formattedTotalSize)")
                    .monospacedDigit()

                Spacer(minLength: 12)

                if let packedInfo = formattedPackedInfo {
                    Text(packedInfo)
                        .monospacedDigit()
                }

                if appState.mode == .browseArchive && appState.isArchiveEncrypted {
                    Label("已加密", systemImage: "lock.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.14))
                        )
                }

                if appState.mode == .browseArchive, let formatName = appState.archiveFormatName {
                    HStack(spacing: 4) {
                        Text(formatName)
                            .font(.caption2.weight(.semibold))
                        if appState.isReadOnlyArchive {
                            Text("只读")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.14))
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func entryTotalSize(_ entry: FileEntry) -> Int64 {
        if entry.isDirectory, let children = entry.children {
            return children.reduce(0) { $0 + entryTotalSize($1) }
        }
        return entry.size
    }
}

#Preview {
    StatusBarView()
        .environment(AppState())
}
