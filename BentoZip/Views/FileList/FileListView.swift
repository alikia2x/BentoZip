import BentoZipCore
import SwiftUI

struct FileListView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteEntries: [FileEntry] = []

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
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.regular)

                        Text(appState.mode == .browseArchive ? String(localized: "Reading archive…") : String(localized: "Loading…"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
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
