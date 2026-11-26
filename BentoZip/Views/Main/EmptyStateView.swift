import AppKit
import BentoZipCore
import SwiftUI

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState

    @State private var isTargeted = false
    @State private var hoveredActionID: String?

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                brandPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 2)
                        )
                        .padding(12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())

            Divider()
                .ignoresSafeArea()

            RecentArchivesSidebar()
                .frame(width: 296)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: isTargeted)
        .onAppear {
            appState.refreshRecentArchives()
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            let allArchives = items.allSatisfy { FormatDetector.isArchiveFile($0) }
            if allArchives {
                for (index, url) in items.enumerated() {
                    DocumentWindowRouter.shared.openArchive(url, from: index == 0 ? appState : nil)
                }
            } else {
                DocumentWindowRouter.shared.openFilesToCompress(items, from: appState)
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
                    shortcut: "⇧⌘N"
                ) {
                    DocumentWindowRouter.shared.presentChooseFilesToCompressPanel(from: appState)
                }

                welcomeActionTile(
                    id: "open",
                    title: "Open Archive",
                    icon: "folder",
                    shortcut: "⌘O"
                ) {
                    DocumentWindowRouter.shared.presentOpenArchivePanel(from: appState)
                }
            }
            .frame(width: 248)

            Text("Drop files or archives anywhere to start")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 14)

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
}
