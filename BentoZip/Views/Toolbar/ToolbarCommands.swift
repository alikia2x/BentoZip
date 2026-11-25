import AppKit
import BentoZipCore
import SwiftUI

struct ToolbarCommands: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

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
                                        chooseDestination: true
                                    )
                                }
                            } label: {
                                Label(
                                    String(localized: "Extract Selected (\(appState.selectedNodes.count))…"),
                                    systemImage: "checkmark.rectangle.stack"
                                )
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
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: urls,
                        progressState: progressState
                    )
                }
            }
        }
    }
}
