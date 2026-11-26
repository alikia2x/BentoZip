import BentoZipCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

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
        @Bindable var uiState = uiState

        Group {
            switch appState.mode {
            case .empty:
                EmptyStateView()
            case .compress, .browseArchive:
                workspaceView(showInspector: $appState.showInspector)
            }
        }
        .background(
            WindowDocumentBridge(
                appState: appState,
                progressState: progressState,
                uiState: uiState,
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
        .sheet(item: $appState.activeConflictPrompt, onDismiss: {
            appState.activeConflictPrompt?.cancel()
            appState.activeConflictPrompt = nil
        }) { prompt in
            ConflictResolutionSheet(prompt: prompt)
        }
        .sheet(item: $uiState.renameTargetEntry) { entry in
            RenameEntrySheet(entry: entry) { newName in
                Task {
                    await appState.coordinator.renameEntry(
                        appState: appState,
                        entry: entry,
                        newName: newName,
                        progressState: progressState
                    )
                }
            }
        }
        .sheet(isPresented: $uiState.showNewFolderSheet) {
            NewFolderSheet(currentSubfolderPath: appState.currentSubfolderPath) { name in
                Task {
                    await appState.coordinator.createFolder(
                        appState: appState,
                        name: name,
                        progressState: progressState
                    )
                }
            }
        }
        .alert(
            testArchiveAlertTitle,
            isPresented: Binding(
                get: { appState.testArchiveResult != nil },
                set: { if !$0 { appState.testArchiveResult = nil } }
            ),
            presenting: appState.testArchiveResult
        ) { _ in
            Button("OK") { appState.testArchiveResult = nil }
        } message: { result in
            if result.passed {
                Text("\"\(result.archiveName)\" passed integrity verification (\(result.itemsCount) items).")
            } else {
                Text(result.errorMessage ?? String(localized: "The archive failed integrity verification."))
            }
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

    private var testArchiveAlertTitle: String {
        guard let result = appState.testArchiveResult else { return "" }
        return result.passed
            ? String(localized: "Archive Verified")
            : String(localized: "Archive Integrity Failed")
    }

    private func workspaceView(showInspector: Binding<Bool>) -> some View {
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
                let targetPrefix = appState.currentSubfolderPath
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: items,
                        targetPrefix: targetPrefix,
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
        .inspector(isPresented: showInspector) {
            CompressionSettingsView()
                .inspectorColumnWidth(min: 240, ideal: 272, max: 400)
        }
    }
}
