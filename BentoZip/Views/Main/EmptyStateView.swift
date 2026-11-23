import AppKit
import BentoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState

    @State private var isTargeted = false
    @State private var hoveredRecentPath: String?

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                dropZoneCard

                if !appState.recentArchiveURLs.isEmpty {
                    recentArchivesCard
                }

                supportedFormatsBadge

                Spacer(minLength: 8)
            }
            .padding(28)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(
            isTargeted
                ? Color.accentColor.opacity(0.05)
                : Color.clear
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isTargeted)
        .onAppear {
            appState.refreshRecentArchives()
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            Task {
                await appState.handleDroppedURLs(items)
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }

    // MARK: - Drop Zone Card

    private var dropZoneCard: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.09))
                    .frame(width: 72, height: 72)

                Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "doc.zipper")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    .symbolEffect(.bounce, value: isTargeted)
            }

            VStack(spacing: 6) {
                Text(isTargeted ? "松开以添加项目" : "拖放文件或压缩包到此处")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("拖入文件或文件夹即可打包压缩，拖入压缩包即可预览与解压")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button {
                    chooseFilesToCompress()
                } label: {
                    Label("选择文件压缩", systemImage: "plus.rectangle.on.folder")
                        .frame(minWidth: 132)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    chooseArchiveToOpen()
                } label: {
                    Label("打开压缩包", systemImage: "archivebox")
                        .frame(minWidth: 124)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.quaternary.opacity(isTargeted ? 0.38 : 0.22))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.25, dash: [7, 5])
                )
        }
        .shadow(
            color: isTargeted ? Color.accentColor.opacity(0.18) : .clear,
            radius: 14,
            y: 4
        )
        .scaleEffect(isTargeted ? 1.015 : 1.0)
    }

    // MARK: - Recent Archives

    private var recentArchivesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("最近项目", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("清除记录") {
                    appState.preferencesManager?.updatePreferences { prefs in
                        prefs.recentArchives.removeAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(appState.recentArchiveURLs.prefix(5), id: \.self) { url in
                    recentArchiveRow(for: url)
                }
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.22))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
    }

    private func recentArchiveRow(for url: URL) -> some View {
        let path = url.path
        let folderPath = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        let isHovered = hoveredRecentPath == path

        return Button {
            Task {
                await appState.coordinator.browseArchive(at: url, appState: appState)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(folderPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                if let formatLabel = archiveFormatBadge(for: url) {
                    Text(formatLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredRecentPath = hovering ? path : (hoveredRecentPath == path ? nil : hoveredRecentPath)
        }
    }

    private func archiveFormatBadge(for url: URL) -> String? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "TAR.GZ" }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return "TAR.BZ2" }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return "TAR.XZ" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip", "zipx": return "ZIP"
        case "7z": return "7z"
        case "tar": return "TAR"
        case "gz", "gzip": return "GZIP"
        case "bz2", "bzip2": return "BZ2"
        case "xz": return "XZ"
        case "rar": return "RAR"
        default: return ext.isEmpty ? nil : ext.uppercased()
        }
    }

    // MARK: - Supported Formats Badge

    private var supportedFormatsBadge: some View {
        HStack(spacing: 6) {
            Text("支持格式")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)

            Text("ZIP · 7z · TAR.GZ · XZ · BZ2 · RAR")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(.quaternary.opacity(0.35))
                )
        }
    }

    // MARK: - Actions

    private func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "选择"
        panel.message = "选择要压缩的文件或文件夹"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            appState.loadFiles(from: panel.urls)
        }
    }

    private func chooseArchiveToOpen() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "打开"
        panel.message = "选择要浏览或解压的压缩包"
        let archiveTypes: [UTType] = [
            .zip, .gzip, .bz2, .archive,
            UTType(filenameExtension: "7z"),
            UTType(filenameExtension: "rar"),
            UTType(filenameExtension: "xz"),
            UTType(filenameExtension: "tar"),
            UTType(filenameExtension: "tgz"),
            UTType(filenameExtension: "tbz"),
            UTType(filenameExtension: "tbz2"),
            UTType(filenameExtension: "txz"),
            UTType(filenameExtension: "zipx")
        ].compactMap { $0 }
        panel.allowedContentTypes = archiveTypes

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.coordinator.browseArchive(at: url, appState: appState)
            }
        }
    }
}

#Preview {
    EmptyStateView()
        .environment(AppState())
}
