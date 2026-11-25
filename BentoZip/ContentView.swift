import BentoZipCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showErrorAlert = false
    @State private var showToolbarDeleteConfirmation = false
    @State private var isTargeted = false

    private var canAcceptFileDrop: Bool {
        appState.mode == .compress || appState.isWritableArchive
    }

    private var windowTitle: String {
        switch appState.mode {
        case .empty:
            return ""
        case .compress:
            return appState.compressionSettings.archiveName.isEmpty
                ? appState.suggestedArchiveName
                : appState.compressionSettings.archiveName
        case .browseArchive:
            return appState.sourceArchiveURL?.lastPathComponent ?? ""
        }
    }

    private var windowSubtitle: String {
        switch appState.mode {
        case .empty:
            return ""
        case .compress:
            return String(localized: "\(appState.rootNodes.count) items")
        case .browseArchive:
            if let format = appState.archiveFormatName {
                return appState.isReadOnlyArchive
                    ? String(localized: "\(format) (Read-Only)")
                    : format
            }
            return ""
        }
    }

    var body: some View {
        @Bindable var appState = appState

        Group {
            switch appState.mode {
            case .empty:
                EmptyStateView()
            case .compress, .browseArchive:
                workspaceView
            }
        }
        .background(
            WindowDocumentBridge(
                appState: appState,
                mode: appState.mode,
                sourceArchiveURL: appState.sourceArchiveURL
            )
            .frame(width: 0, height: 0)
        )
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbarBackground(appState.mode == .empty ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarCommands(
                showDeleteConfirmation: $showToolbarDeleteConfirmation,
                selectedCount: appState.selectedNodes.count,
                isLoading: appState.isLoading,
                isOperationInProgress: progressState.isOperationInProgress,
                hasRootItems: !appState.rootNodes.isEmpty
            )
        }
        .onOpenURL { url in
            DocumentWindowRouter.shared.openExternalURLs([url])
        }
        .onChange(of: appState.lastError) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .sheet(isPresented: $appState.needsPasswordPrompt) {
            PasswordPromptSheet { password in
                await appState.coordinator.submitPassword(
                    password,
                    appState: appState,
                    progressState: progressState
                )
            }
            .environment(appState)
            .interactiveDismissDisabled(appState.isLoading)
        }
        .alert("Operation Failed", isPresented: $showErrorAlert) {
            Button("OK") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
        .confirmationDialog(
            Text("Delete \(appState.selectedNodes.count) selected items from archive?"),
            isPresented: $showToolbarDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let entriesToDelete = appState.selectedNodes.map { $0.toFileEntry() }
                Task {
                    await appState.coordinator.removeEntries(
                        appState: appState,
                        entries: entriesToDelete,
                        progressState: progressState
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This modifies the archive and cannot be undone.")
        }
    }

    private var workspaceView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FileListView()
                BreadcrumbView()
                StatusBarView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { items, _ in
                guard !items.isEmpty, canAcceptFileDrop else { return false }
                if appState.mode == .compress {
                    appState.addEntries(from: items)
                    return true
                } else if appState.isWritableArchive {
                    Task {
                        await appState.coordinator.addEntries(
                            appState: appState,
                            urls: items,
                            progressState: progressState
                        )
                    }
                    return true
                }
                return false
            } isTargeted: { targeted in
                isTargeted = targeted && canAcceptFileDrop
            }
            .overlay {
                if isTargeted && canAcceptFileDrop {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        )
                        .padding(6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: isTargeted)

            if appState.showInspector {
                Divider()
                    .ignoresSafeArea(edges: .top)

                CompressionSettingsView()
                    .frame(width: 268)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }
}
