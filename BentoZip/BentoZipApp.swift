import AppKit
import SwiftUI
import SwiftData
import BentoZipCore

@main
struct BentoZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var progressState = ProgressState()
    private let preferencesManager: PreferencesManager
    private let sharedModelContainer: ModelContainer

    init() {
        let manager = PreferencesManager()
        let container = Self.createModelContainer(configuring: manager)
        let initialAppState = AppState()
        initialAppState.preferencesManager = manager
        self.preferencesManager = manager
        self.sharedModelContainer = container
        _appState = State(initialValue: initialAppState)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(progressState)
                .frame(minWidth: 700, minHeight: 440)
        }
        .defaultSize(width: 860, height: 540)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            InspectorCommands()
        }
        .modelContainer(sharedModelContainer)

        Window("Progress", id: "progress") {
            ProgressWindowView()
                .environment(progressState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            DragDropManager.shared.cleanup()
        }
    }
}
