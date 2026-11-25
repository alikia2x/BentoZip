import BentoZipCore
import SwiftUI

struct FileListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteEntries: [FileEntry] = []

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var loadingStageTitle: String {
        if appState.mode == .browseArchive {
            if appState.browseStage == .unpackingOuter {
                return String(localized: "Decompressing archive stream…")
            }
            return String(localized: "Reading archive…")
        }
        return String(localized: "Loading…")
    }

    var body: some View {
        FinderFileListRepresentable(
            appState: appState,
            progressState: progressState,
            mode: appState.mode,
            sourceArchiveURL: appState.sourceArchiveURL,
            showInspector: appState.showInspector,
            treeStructureRevision: appState.treeStructureRevision,
            nodeUpdateRevision: appState.nodeUpdateRevision,
            selectedEntryIDs: appState.selectedEntryIDs
        ) { entries in
            pendingDeleteEntries = entries
            showDeleteConfirmation = true
        }
        .overlay {
            if appState.displayedNodes.isEmpty {
                if appState.isLoading {
                    VStack(spacing: 10) {
                        Text(loadingStageTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)

                        if let progress = appState.browseProgress {
                            ProgressView(value: progress, total: 1.0)
                                .progressViewStyle(.linear)
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 220)

                            HStack(spacing: 10) {
                                Text("\(Int((progress * 100).rounded()))%")
                                if appState.browseTotalBytes > 0 {
                                    Text("\(Self.byteFormatter.string(fromByteCount: appState.browseProcessedBytes)) / \(Self.byteFormatter.string(fromByteCount: appState.browseTotalBytes))")
                                } else if appState.browseProcessedBytes > 0 {
                                    Text(Self.byteFormatter.string(fromByteCount: appState.browseProcessedBytes))
                                }
                            }
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.regular)
                        }

                        if appState.mode == .browseArchive {
                            Button("Cancel") {
                                appState.reset()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                } else {
                    Text("Empty Folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
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
}
