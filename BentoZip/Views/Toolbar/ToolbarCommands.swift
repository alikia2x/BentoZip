import AppKit
import BentoZipCore
import SwiftUI

struct ToolbarCommands: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(WorkspaceUIState.self) private var uiState

    @Binding var showDeleteConfirmation: Bool
    let selectedCount: Int
    let isLoading: Bool
    let isOperationInProgress: Bool
    let hasRootItems: Bool

    private var isBusy: Bool { isLoading || isOperationInProgress }

    var body: some ToolbarContent {
        @Bindable var appState = appState

        if appState.mode != .empty {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    appState.navigateUp()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!appState.canNavigateUp)
                .help("Back")

                Button {
                    appState.coordinator.detachWindowProgress(progressState)
                    appState.reset()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to Home")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if appState.mode == .compress {
                    Button {
                        chooseAndAddFiles()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(isBusy)
                    .help("Add Files or Folders")

                    Button {
                        appState.removeSelectedEntries()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(selectedCount == 0 || isBusy)
                    .help("Remove Selected")

                    Button {
                        Task {
                            await appState.coordinator.compress(
                                appState: appState,
                                progressState: progressState
                            )
                        }
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                    .disabled(!hasRootItems || isBusy)
                    .help("Create Archive")
                } else if appState.mode == .browseArchive {
                    if appState.isWritableArchive {
                        Button {
                            chooseAndAddFiles()
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .disabled(isBusy)
                        .help("Add to Archive")

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedCount == 0 || isBusy)
                        .help("Delete Selected from Archive")
                    }

                    Menu {
                        Button {
                            Task {
                                await appState.coordinator.extract(
                                    appState: appState,
                                    progressState: progressState,
                                    chooseDestination: false
                                )
                            }
                        } label: {
                            Label("Extract Here", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            Task {
                                await appState.coordinator.extract(
                                    appState: appState,
                                    progressState: progressState,
                                    chooseDestination: true
                                )
                            }
                        } label: {
                            Label("Extract To…", systemImage: "folder.badge.plus")
                        }

                        if !appState.selectedNodes.isEmpty {
                            Divider()
                            Button {
                                let entries = appState.selectedNodes.map { $0.toFileEntry() }
                                Task {
                                    await appState.coordinator.extract(
                                        appState: appState,
                                        progressState: progressState,
                                        entries: entries,
                                        chooseDestination: false
                                    )
                                }
                            } label: {
                                Label("Extract Selected Here", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                let entries = appState.selectedNodes.map { $0.toFileEntry() }
                                Task {
                                    await appState.coordinator.extract(
                                        appState: appState,
                                        progressState: progressState,
                                        entries: entries,
                                        chooseDestination: true
                                    )
                                }
                            } label: {
                                Label("Extract Selected…", systemImage: "checkmark.rectangle.stack")
                            }
                        }
                    } label: {
                        Label("Extract", systemImage: "square.and.arrow.down")
                    } primaryAction: {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                chooseDestination: false
                            )
                        }
                    }
                    .disabled(isBusy)
                    .help("Extract")
                }
            }

            if #available(macOS 26.0, *) {
                if appState.isSearchVisible {
                    ToolbarItem(placement: .automatic) {
                        ToolbarSearchPill(
                            text: $appState.searchQuery,
                            isPresented: $appState.isSearchVisible,
                            focusRequestID: uiState.searchFocusRequestID,
                            onCommitToResults: { uiState.requestOutlineFocus() }
                        )
                        .padding(.horizontal, 9)
                        .frame(minWidth: 164, idealWidth: 196, maxWidth: 224)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    }

                    ToolbarSpacer(.fixed, placement: .automatic)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                appState.isSearchVisible = true
                            }
                            uiState.requestSearchFocus()
                        } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        .help("Find")
                    }
                }
            } else {
                ToolbarItem(placement: .automatic) {
                    if appState.isSearchVisible {
                        ToolbarSearchPill(
                            text: $appState.searchQuery,
                            isPresented: $appState.isSearchVisible,
                            focusRequestID: uiState.searchFocusRequestID,
                            onCommitToResults: { uiState.requestOutlineFocus() }
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .frame(minWidth: 164, idealWidth: 196, maxWidth: 224)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.75)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                appState.isSearchVisible = true
                            }
                            uiState.requestSearchFocus()
                        } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        .help("Find")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        appState.showInspector.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(appState.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        } else {
            // Keep an invisible placeholder item in `.empty` mode so macOS preserves the same
            // unified toolbar height and traffic-light coordinates as the workspace window.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func chooseAndAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let urls = panel.urls
            if appState.mode == .compress {
                appState.addEntries(from: urls)
            } else if appState.isWritableArchive {
                let targetPrefix = appState.currentSubfolderPath
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: urls,
                        targetPrefix: targetPrefix,
                        progressState: progressState
                    )
                }
            }
        }
    }
}

private struct ToolbarSearchPill: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    let focusRequestID: UInt64
    let onCommitToResults: () -> Void

    @FocusState private var isFocused: Bool
    @State private var hasActivatedFocus = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("", text: $text, prompt: Text("Search"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    onCommitToResults()
                }
                .onKeyPress(.downArrow) {
                    onCommitToResults()
                    return .handled
                }
                .onKeyPress(.escape) {
                    withAnimation(.snappy(duration: 0.18)) {
                        text = ""
                        isPresented = false
                    }
                    onCommitToResults()
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    focusField()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .onAppear {
            focusField()
        }
        .onChange(of: focusRequestID) { _, _ in
            focusField()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                hasActivatedFocus = true
            } else if hasActivatedFocus &&
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.async {
                    if !isFocused &&
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        withAnimation(.snappy(duration: 0.18)) {
                            isPresented = false
                        }
                    }
                }
            }
        }
    }

    private func focusField() {
        DispatchQueue.main.async {
            isFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}
