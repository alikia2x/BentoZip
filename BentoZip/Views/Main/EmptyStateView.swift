import AppKit
import BentoZipCore
import SwiftUI
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState

    @State private var isTargeted = false
    @State private var hoveredActionID: String?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                brandPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())

                Divider()
                    .ignoresSafeArea()

                RecentArchivesSidebar()
                    .frame(width: 296)
                    .frame(maxHeight: .infinity)
                    .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
            }

            if isTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                    )
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isTargeted)
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

    private var brandPane: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .scaleEffect(isTargeted ? 1.06 : 1.0)

                Text("BentoZip")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 34)

            VStack(spacing: 8) {
                welcomeActionTile(
                    id: "create",
                    title: "New Archive",
                    icon: "plus.square.on.square",
                    shortcut: "⌘N"
                ) {
                    chooseFilesToCompress()
                }
                .keyboardShortcut("n", modifiers: .command)

                welcomeActionTile(
                    id: "open",
                    title: "Open Archive",
                    icon: "folder",
                    shortcut: "⌘O"
                ) {
                    chooseArchiveToOpen()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            .frame(width: 248)

            Spacer()
            Spacer().frame(height: 16)
        }
        .padding(.horizontal, 36)
    }

    private func welcomeActionTile(
        id: String,
        title: LocalizedStringKey,
        icon: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredActionID == id

        return Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.primary.opacity(0.75))
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0.06), lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredActionID = hovering ? id : (hoveredActionID == id ? nil : hoveredActionID)
            }
        }
    }

    private func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            appState.loadFiles(from: panel.urls)
        }
    }

    private func chooseArchiveToOpen() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Open")
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
