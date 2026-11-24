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

        Form {
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
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Button("Extract To…") {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: true,
                                openWindow: openWindow
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

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
                            .frame(minWidth: 68)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private var archiveMetaSummary: String {
        let format = appState.archiveFormatName ?? String(localized: "Archive")
        return appState.isReadOnlyArchive
            ? String(localized: "\(format) (Read-Only)")
            : format
    }
}
