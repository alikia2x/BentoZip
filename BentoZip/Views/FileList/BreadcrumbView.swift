import AppKit
import BentoZipCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style bottom Path Bar displayed above the Status Bar when inside a subfolder or scanning.
struct BreadcrumbView: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredSegmentIndex: Int?

    private var rootLabel: String {
        if appState.mode == .browseArchive, let name = appState.sourceArchiveURL?.lastPathComponent {
            return name
        }
        return String(localized: "Root")
    }

    private var rootIcon: NSImage {
        if appState.mode == .browseArchive, let path = appState.sourceArchiveURL?.path {
            return FileIconCache.icon(forFileAt: path)
        }
        return NSWorkspace.shared.icon(for: .folder)
    }

    var body: some View {
        if appState.canNavigateUp || appState.isViewingNestedArchive || appState.isLoading || appState.isCalculatingSizes {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 4) {
                    if appState.canNavigateUp || appState.isViewingNestedArchive {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 2) {
                                ForEach(Array(appState.nestedArchiveStack.enumerated()), id: \.element.id) { stackIndex, frame in
                                    if stackIndex > 0 {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 2)
                                    }

                                    pathSegment(
                                        title: frame.archiveName,
                                        icon: FileIconCache.icon(forFileAt: frame.archiveURL.path),
                                        index: stackIndex,
                                        isCurrent: false
                                    ) {
                                        appState.popNestedArchive(toStackIndex: stackIndex)
                                    }
                                }

                                if !appState.nestedArchiveStack.isEmpty {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 2)
                                }

                                let currentRootIndex = appState.nestedArchiveStack.count
                                pathSegment(
                                    title: rootLabel,
                                    icon: rootIcon,
                                    index: currentRootIndex,
                                    isCurrent: appState.navigationNodes.isEmpty
                                ) {
                                    appState.navigateBack(to: 0)
                                }

                                ForEach(Array(appState.navigationNodes.enumerated()), id: \.element.id) { index, node in
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 2)

                                    let isLast = index == appState.navigationNodes.count - 1
                                    pathSegment(
                                        title: node.name,
                                        icon: FileIconCache.icon(for: node),
                                        index: currentRootIndex + 1 + index,
                                        isCurrent: isLast
                                    ) {
                                        appState.navigateBack(to: index + 1)
                                    }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    if appState.isLoading || appState.isCalculatingSizes {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.bar)
            }
        }
    }

    private func pathSegment(
        title: String,
        icon: NSImage,
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
            HStack(spacing: 4) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 11.5, weight: isCurrent ? .medium : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSegmentIndex = hovering ? index : (hoveredSegmentIndex == index ? nil : hoveredSegmentIndex)
        }
    }
}
