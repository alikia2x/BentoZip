import BentoZipCore
import SwiftUI

struct CompressionSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.mode {
            case .compress:
                CompressInspectorView()
            case .browseArchive:
                ArchiveInfoInspectorView()
            case .empty:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(edges: .top))
    }
}
