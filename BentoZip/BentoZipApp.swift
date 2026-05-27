import SwiftUI
import SwiftData
import BentoZipCore

@main
struct BentoZipApp: App {
    @State private var progressState = ProgressState()
    private let preferencesManager = PreferencesManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(progressState)
        }
        .commands {
            InspectorCommands()
        }
        .modelContainer(createModelContainer())

        WindowGroup(id: "progress") {
            ProgressWindowView()
                .environment(progressState)
        }
        .defaultSize(width: 380, height: 140)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    private func createModelContainer() -> ModelContainer {
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