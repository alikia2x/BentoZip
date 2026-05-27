import SwiftUI
import BentoZipCore

struct ContentView: View {
    @State private var appState = AppState()
    @Environment(ProgressState.self) private var progressState
    @State private var showErrorAlert = false
    @State private var isTargeted = false

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            switch appState.mode {
            case .empty:
                EmptyStateView()
            case .compress, .browseArchive:
                fileBrowsingView
            }
        }
        .inspector(isPresented: $appState.showInspector) {
            CompressionSettingsView()
                .environment(appState)
                .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarCommands()
        }
        .environment(appState)
        .disabled(progressState.isOperationInProgress)
        .onChange(of: appState.lastError) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .alert("错误", isPresented: $showErrorAlert) {
            Button("确定") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
    }

    private var fileBrowsingView: some View {
        VStack(spacing: 0) {
            BreadcrumbView()
            FileListView()
        }
        .dropDestination(for: URL.self) { items, _ in
            guard appState.mode == .compress else { return false }
            appState.addEntries(from: items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .overlay {
            if isTargeted && appState.mode == .compress {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(ProgressState())
}