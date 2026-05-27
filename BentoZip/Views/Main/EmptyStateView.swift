import SwiftUI
import BentoZipCore

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 64))
                .foregroundStyle(isTargeted ? .blue : .secondary)

            Text("拖放文件或文件夹到此处进行压缩")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("或拖放压缩包进行解压")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("支持格式: ZIP, 7z, tar.gz")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.blue.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { items, _ in
            handleDrop(items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    private func handleDrop(_ urls: [URL]) {
        guard let first = urls.first else { return }

        if FormatDetector.isArchiveFile(first) {
            Task { await appState.coordinator.browseArchive(at: first, appState: appState) }
        } else {
            appState.loadFiles(from: urls)
        }
    }
}

#Preview {
    EmptyStateView()
        .environment(AppState())
}
