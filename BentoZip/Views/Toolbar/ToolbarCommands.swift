import SwiftUI
import BentoZipCore

struct ToolbarCommands: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    private var formatBinding: Binding<ArchiveFormat> {
        Binding(
            get: { appState.compressionSettings.format },
            set: { appState.compressionSettings.format = $0 }
        )
    }

    private var canDelete: Bool {
        appState.mode == .compress && !appState.selectedEntryIDs.isEmpty
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                if panel.runModal() == .OK {
                    let urls = panel.urls
                    appState.addEntries(from: urls)
                    if appState.mode == .browseArchive {
                        Task { await appState.coordinator.addEntries(appState: appState, urls: urls, progressState: progressState, openWindow: openWindow) }
                    }
                }
            } label: {
                Label("添加", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }

            Button {
                appState.removeSelectedEntries()
            } label: {
                Label("删除", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!canDelete)

            Button {
                Task { await appState.coordinator.compress(appState: appState, progressState: progressState, openWindow: openWindow) }
            } label: {
                Label("压缩", systemImage: "doc.zipper")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(appState.mode != .compress)

            Button {
                Task { await appState.coordinator.extract(appState: appState, progressState: progressState, openWindow: openWindow) }
            } label: {
                Label("解压", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(appState.mode != .browseArchive)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                progressState.shouldDismiss = true
                appState.reset()
            } label: {
                Label("主页", systemImage: "house")
            }
            .disabled(appState.mode == .empty)
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.showInspector.toggle()
            } label: {
                Label("边栏", systemImage: "sidebar.trailing")
            }
        }
    }
}
