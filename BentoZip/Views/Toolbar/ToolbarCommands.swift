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
                }
            } label: {
                Label("添加文件", systemImage: "plus")
            }

            Button {
                appState.removeSelectedEntries()
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!canDelete)

            Button {
                Task { await appState.coordinator.compress(appState: appState, progressState: progressState, openWindow: openWindow) }
            } label: {
                Label("压缩", systemImage: "doc.zipper")
            }
            .disabled(appState.mode != .compress)

            Button {
                Task { await appState.coordinator.extract(appState: appState, progressState: progressState, openWindow: openWindow) }
            } label: {
                Label("解压", systemImage: "square.and.arrow.down")
            }
            .disabled(appState.mode != .browseArchive)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
        }
    }
}
