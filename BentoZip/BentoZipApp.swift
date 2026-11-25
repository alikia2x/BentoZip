import AppKit
import BentoZipCore
import Observation
import SwiftData
import SwiftUI

@main
struct BentoZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let preferencesManager: PreferencesManager
    private let sharedModelContainer: ModelContainer
    @State private var menuRecents: RecentMenuModel

    init() {
        let manager = PreferencesManager()
        let container = Self.createModelContainer(configuring: manager)
        self.preferencesManager = manager
        self.sharedModelContainer = container
        _menuRecents = State(initialValue: RecentMenuModel(preferencesManager: manager))
    }

    var body: some Scene {
        WindowGroup(id: "workspace", for: WorkspaceLaunchRequest.self) { $request in
            WindowRootView(
                initialRequest: request,
                preferencesManager: preferencesManager
            )
        } defaultValue: {
            .empty
        }
        .defaultSize(width: 860, height: 540)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            InspectorCommands()

            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    DocumentWindowRouter.shared.openNewEmptyWindow()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Archive from Files…") {
                    DocumentWindowRouter.shared.presentChooseFilesToCompressPanel()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Open Archive…") {
                    DocumentWindowRouter.shared.presentOpenArchivePanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if menuRecents.archiveURLs.isEmpty {
                        Button("No Recent Archives") {}
                            .disabled(true)
                    } else {
                        ForEach(menuRecents.archiveURLs, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                DocumentWindowRouter.shared.openArchive(url)
                            }
                        }

                        Divider()

                        Button("Clear Menu") {
                            preferencesManager.updatePreferences { prefs in
                                prefs.recentArchives.removeAll()
                            }
                        }
                    }
                }
            }

            CommandGroup(after: .windowList) {
                Divider()
                Button("Progress") {
                    TransferWindowController.shared.showProgressWindow(makeKey: true)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }
        .modelContainer(sharedModelContainer)

        Settings {
            SettingsView(preferencesManager: preferencesManager)
                .modelContainer(sharedModelContainer)
        }
    }

    private static func createModelContainer(configuring preferencesManager: PreferencesManager) -> ModelContainer {
        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            preferencesManager.configure(with: container.mainContext)
            return container
        } catch {
            let container = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            preferencesManager.configure(with: container.mainContext)
            return container
        }
    }
}

private struct WindowRootView: View {
    let initialRequest: WorkspaceLaunchRequest
    let preferencesManager: PreferencesManager

    @Environment(\.openWindow) private var openWindow
    @State private var appState = AppState()
    @State private var progressState = ProgressState()
    @State private var hasAppliedInitialRequest = false

    var body: some View {
        ContentView()
            .environment(appState)
            .environment(progressState)
            .frame(minWidth: 700, minHeight: 440)
            .onAppear {
                DocumentWindowRouter.shared.configureWindowOpener { request in
                    openWindow(id: "workspace", value: request)
                }
                TransferWindowController.shared.startObserving()

                if appState.preferencesManager == nil {
                    appState.preferencesManager = preferencesManager
                }
                guard !hasAppliedInitialRequest else { return }
                hasAppliedInitialRequest = true

                switch initialRequest {
                case .empty:
                    break
                case .openArchive(let url):
                    Task {
                        await appState.coordinator.browseArchive(at: url, appState: appState)
                    }
                case .compressFiles(let urls):
                    appState.loadFiles(from: urls)
                }
            }
            .onDisappear {
                appState.cancelBackgroundTasks()
            }
    }
}

/// Live-updating model backing the File > Open Recent submenu in the macOS menu bar.
@Observable
@MainActor
private final class RecentMenuModel {
    private let preferencesManager: PreferencesManager
    @ObservationIgnored nonisolated(unsafe) private var observerToken: NSObjectProtocol?
    private(set) var archiveURLs: [URL] = []

    init(preferencesManager: PreferencesManager) {
        self.preferencesManager = preferencesManager
        refresh()
        observerToken = NotificationCenter.default.addObserver(
            forName: PreferencesManager.preferencesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    private func refresh() {
        let paths = preferencesManager.loadPreferences().recentArchives
        archiveURLs = paths.map { URL(fileURLWithPath: $0) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            TransferWindowController.shared.startObserving()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            DocumentWindowRouter.shared.openExternalURLs(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag && !DocumentWindowRouter.shared.hasVisibleWorkspaceWindows {
                DocumentWindowRouter.shared.openNewEmptyWindow()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            TransferManager.shared.cancelAll()
            DragDropManager.shared.cleanup()
        }
    }
}
