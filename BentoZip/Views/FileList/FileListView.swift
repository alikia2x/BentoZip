import AppKit
import BentoZipCore
import SwiftUI

struct FileListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

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

    private var hasActiveSearchQuery: Bool {
        !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        FinderFileListRepresentable(
            appState: appState,
            progressState: progressState,
            uiState: uiState,
            mode: appState.mode,
            sourceArchiveURL: appState.sourceArchiveURL,
            showInspector: appState.showInspector,
            treeStructureRevision: appState.treeStructureRevision,
            nodeUpdateRevision: appState.nodeUpdateRevision,
            isSearchVisible: appState.isSearchVisible,
            selectedEntryIDs: appState.selectedEntryIDs
        ) { entries in
            pendingDeleteEntries = entries
            showDeleteConfirmation = true
        }
        .overlay {
            if appState.displayedNodes.isEmpty {
                if appState.isLoading {
                    loadingOverlay
                } else {
                    Text(hasActiveSearchQuery ? "No Results" : "Empty Folder")
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

    private var loadingOverlay: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            VStack(spacing: 10) {
                if appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL {
                    Image(nsImage: FileIconCache.icon(forFileAt: archiveURL.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

                    Text(archiveURL.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300)
                }

                if let progress = appState.browseProgress {
                    VStack(spacing: 6) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .labelsHidden()
                            .controlSize(.small)

                        HStack(spacing: 8) {
                            Text(loadingStageTitle)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(determinateDetailText(progress: progress))
                                .monospacedDigit()
                                .fixedSize()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 248)
                    .padding(.top, 2)
                } else {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.85)

                        Text(indeterminateStatusText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if appState.mode == .browseArchive {
                    Button("Cancel") {
                        appState.reset()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 6)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func determinateDetailText(progress: Double) -> String {
        let pct = "\(Int((progress * 100).rounded()))%"
        if appState.browseTotalBytes > 0 {
            let done = Self.byteFormatter.string(fromByteCount: appState.browseProcessedBytes)
            let total = Self.byteFormatter.string(fromByteCount: appState.browseTotalBytes)
            return "\(pct)  \(done) / \(total)"
        }
        if appState.browseProcessedBytes > 0 {
            let done = Self.byteFormatter.string(fromByteCount: appState.browseProcessedBytes)
            return "\(pct)  \(done)"
        }
        return pct
    }

    private var indeterminateStatusText: String {
        if appState.browseProcessedBytes > 0 {
            let done = Self.byteFormatter.string(fromByteCount: appState.browseProcessedBytes)
            return "\(loadingStageTitle) \(done)"
        }
        return loadingStageTitle
    }
}
