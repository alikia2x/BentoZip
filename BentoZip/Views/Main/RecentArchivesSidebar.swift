import AppKit
import BentoZipCore
import SwiftUI

struct RecentArchivesSidebar: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredRecentPath: String?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recents")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !appState.recentArchiveItems.isEmpty {
                    Button("Clear") {
                        appState.preferencesManager?.updatePreferences { prefs in
                            prefs.recentArchives.removeAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if appState.recentArchiveItems.isEmpty {
                Spacer()
                Text("No Recent Archives")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(appState.recentArchiveItems) { item in
                            recentRow(for: item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func recentRow(for item: RecentArchiveItem) -> some View {
        let path = item.url.path
        let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let isHovered = hoveredRecentPath == path

        return Button {
            DocumentWindowRouter.shared.openArchive(item.url, from: appState)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: FileIconCache.icon(forFileAt: path))
                    .resizable()
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text(folder)
                            .lineLimit(1)
                            .truncationMode(.head)

                        Spacer(minLength: 6)

                        if let size = item.fileSize {
                            Text(Self.byteFormatter.string(fromByteCount: size))
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredRecentPath = hovering ? path : (hoveredRecentPath == path ? nil : hoveredRecentPath)
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Remove from Recents") {
                appState.preferencesManager?.updatePreferences { prefs in
                    prefs.recentArchives.removeAll { $0 == path }
                }
            }
        }
    }
}
