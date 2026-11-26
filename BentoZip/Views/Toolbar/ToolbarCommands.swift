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
                        ToolbarSearchField(
                            text: $appState.searchQuery,
                            isPresented: $appState.isSearchVisible,
                            focusRequestID: uiState.searchFocusRequestID
                        )
                        .frame(width: 210)
                    }
                    .sharedBackgroundVisibility(.hidden)

                    ToolbarSpacer(.fixed, placement: .automatic)
                } else {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            appState.isSearchVisible = true
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
                        ToolbarSearchField(
                            text: $appState.searchQuery,
                            isPresented: $appState.isSearchVisible,
                            focusRequestID: uiState.searchFocusRequestID
                        )
                        .frame(width: 210)
                    } else {
                        Button {
                            appState.isSearchVisible = true
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

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let focusRequestID: UInt64

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = FocusableToolbarSearchField()
        searchField.placeholderString = String(localized: "Search")
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.centersPlaceholder = false
        searchField.bezelStyle = .roundedBezel
        searchField.controlSize = .regular
        searchField.delegate = context.coordinator
        searchField.stringValue = text
        searchField.lastHandledFocusRequestID = focusRequestID
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isPresented = $isPresented
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if let field = nsView as? FocusableToolbarSearchField,
           field.lastHandledFocusRequestID != focusRequestID {
            field.lastHandledFocusRequestID = focusRequestID
            field.focusInWindow()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isPresented: Binding<Bool>

        init(text: Binding<String>, isPresented: Binding<Bool>) {
            self.text = text
            self.isPresented = isPresented
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                text.wrappedValue = ""
                isPresented.wrappedValue = false
                return true
            }
            return false
        }
    }

    private final class FocusableToolbarSearchField: NSSearchField {
        private var hasRequestedInitialFocus = false
        var lastHandledFocusRequestID: UInt64 = 0

        override var intrinsicContentSize: NSSize {
            NSSize(width: 210, height: super.intrinsicContentSize.height)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasRequestedInitialFocus else { return }
            hasRequestedInitialFocus = true
            focusInWindow()
        }

        func focusInWindow() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
