import SwiftUI
import BentoZipCore

struct BreadcrumbView: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredSegmentIndex: Int?

    private var rootLabel: String {
        if appState.mode == .browseArchive, let name = appState.sourceArchiveURL?.lastPathComponent {
            return name
        }
        return "全部文件"
    }

    private var rootIcon: String {
        appState.mode == .browseArchive ? "doc.zipper" : "folder.fill"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    appState.navigateUp()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!appState.canNavigateUp)
                .help("返回上一级 (⌘↑)")

                Divider()
                    .frame(height: 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        breadcrumbButton(
                            title: rootLabel,
                            icon: rootIcon,
                            index: 0,
                            isCurrent: appState.navigationPath.isEmpty
                        ) {
                            appState.navigateBack(to: 0)
                        }

                        ForEach(Array(appState.navigationPath.enumerated()), id: \.element.id) { index, entry in
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)

                            let isLast = index == appState.navigationPath.count - 1
                            breadcrumbButton(
                                title: entry.name,
                                icon: "folder.fill",
                                index: index + 1,
                                isCurrent: isLast
                            ) {
                                appState.navigateBack(to: index + 1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if appState.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在扫描...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 8)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)

            Divider()
        }
        .animation(.easeInOut(duration: 0.15), value: appState.isLoading)
    }

    private func breadcrumbButton(
        title: String,
        icon: String,
        index: Int,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredSegmentIndex == index && !isCurrent

        return Button {
            if !isCurrent {
                action()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)

                Text(title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.secondary.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .onHover { hovering in
            hoveredSegmentIndex = hovering ? index : (hoveredSegmentIndex == index ? nil : hoveredSegmentIndex)
        }
    }
}

#Preview {
    BreadcrumbView()
        .environment(AppState())
}
