import AppKit
import BentoZipCore
import SwiftUI

struct ArchiveInfoInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        let totalCount = appState.totalEntryCount
        let uncompressedStr = Self.byteFormatter.string(fromByteCount: appState.totalSize)

        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if let archiveURL = appState.sourceArchiveURL {
                        HStack(spacing: 10) {
                            Image(nsImage: FileIconCache.icon(forFileAt: archiveURL.path))
                                .resizable()
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(archiveURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)

                                Text(archiveMetaSummary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Info")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        infoRow("Items", value: String(localized: "\(totalCount) items"))
                        infoRow("Size", value: uncompressedStr)

                        if let packed = appState.totalPackedSize, packed > 0 {
                            infoRow("Packed", value: Self.byteFormatter.string(fromByteCount: packed))

                            if appState.totalSize > 0 && packed <= appState.totalSize {
                                let saved = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
                                infoRow("Saved Ratio", value: "\(saved)%")
                            }
                        }

                        if appState.isArchiveEncrypted {
                            infoRow("Encryption", value: String(localized: "Encrypted"))
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            VStack(spacing: 8) {
                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: false,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Text("Extract")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: true,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Text("Extract To…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(14)
        }
    }

    private func infoRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }

    private var archiveMetaSummary: String {
        let format = appState.archiveFormatName ?? String(localized: "Archive")
        return appState.isReadOnlyArchive
            ? String(localized: "\(format) (Read-Only)")
            : format
    }
}
