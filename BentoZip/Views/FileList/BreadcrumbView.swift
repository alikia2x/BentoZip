import SwiftUI
import BentoZipCore

struct BreadcrumbView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if !appState.navigationPath.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("全部文件") {
                        appState.navigateBack(to: 0)
                    }
                    .buttonStyle(.link)

                    ForEach(Array(appState.navigationPath.enumerated()), id: \.element.id) { index, entry in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        if index == appState.navigationPath.count - 1 {
                            Text(entry.name)
                                .foregroundStyle(.primary)
                                .font(.callout)
                        } else {
                            Button(entry.name) {
                                appState.navigateBack(to: index + 1)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}

#Preview {
    BreadcrumbView()
        .environment(AppState())
        .environment(ProgressState())
}
