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
        if appState.mode != .empty {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.coordinator.detachWindowProgress(progressState)
                    appState.reset()
                } label: {
                    Label("Home", systemImage: "chevron.backward")
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
                            uiState.showNewFolderSheet = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .disabled(isBusy)
                        .help("New Folder")

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedCount == 0 || isBusy)
                        .help("Delete Selected from Archive")
                    }

                    Button {
                        Task {
                            await appState.coordinator.testArchive(
                                appState: appState,
                                progressState: progressState
                            )
                        }
                    } label: {
                        Label("Test Archive", systemImage: "checkmark.shield")
                    }
                    .disabled(isBusy)
                    .help("Test Archive")

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

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    if appState.isSearchVisible {
                        appState.searchQuery = ""
                        appState.isSearchVisible = false
                    } else {
                        appState.isSearchVisible = true
                        uiState.requestSearchFocus()
                    }
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find")

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
