import AppKit
import BentoZipCore
import SwiftUI

struct ToolbarCommands: ToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @Binding var showDeleteConfirmation: Bool

    private var canAdd: Bool {
        guard !appState.isLoading else { return false }
        switch appState.mode {
        case .compress:
            return true
        case .browseArchive:
            return appState.isWritableArchive
        case .empty:
            return false
        }
    }

    private var canDelete: Bool {
        guard !appState.selectedEntryIDs.isEmpty, !appState.isLoading else { return false }
        switch appState.mode {
        case .compress:
            return true
        case .browseArchive:
            return appState.isWritableArchive
        case .empty:
            return false
        }
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                chooseAndAddFiles()
            } label: {
                Label("添加", systemImage: "plus")
            }
            .disabled(!canAdd)
            .help(addTooltip)

            Button {
                if appState.mode == .compress {
                    appState.removeSelectedEntries()
                } else if appState.isWritableArchive {
                    showDeleteConfirmation = true
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!canDelete)
            .help(deleteTooltip)

            Button {
                Task {
                    await appState.coordinator.compress(
                        appState: appState,
                        progressState: progressState,
                        openWindow: openWindow
                    )
                }
            } label: {
                Label("压缩", systemImage: "doc.zipper")
            }
            .disabled(appState.mode != .compress || appState.fileEntries.isEmpty || appState.isLoading)
            .help("打包生成压缩包")

            Menu {
                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: false,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Label("解压到当前目录", systemImage: "square.and.arrow.down")
                }

                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: true,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Label("解压到...", systemImage: "folder.badge.plus")
                }

                if !appState.selectedEntries.isEmpty {
                    Divider()
                    Button {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                entries: appState.selectedEntries,
                                chooseDestination: true,
                                openWindow: openWindow
                            )
                        }
                    } label: {
                        Label("解压所选项目 (\(appState.selectedEntries.count))...", systemImage: "checkmark.rectangle.stack")
                    }
                }
            } label: {
                Label("解压", systemImage: "square.and.arrow.down")
            } primaryAction: {
                Task {
                    await appState.coordinator.extract(
                        appState: appState,
                        progressState: progressState,
                        chooseDestination: false,
                        openWindow: openWindow
                    )
                }
            }
            .disabled(appState.mode != .browseArchive || appState.isLoading)
            .help("解压压缩包（点击下拉可选择目标位置）")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                appState.coordinator.cancelOperation(progressState: progressState)
                appState.reset()
            } label: {
                Label("主页", systemImage: "house")
            }
            .disabled(appState.mode == .empty)
            .help("返回主页")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                appState.showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏右侧边栏")
        }
    }

    private var addTooltip: String {
        if appState.mode == .browseArchive && !appState.isWritableArchive {
            return "当前压缩包为只读格式，不支持添加文件"
        }
        return appState.mode == .browseArchive ? "添加文件到压缩包" : "添加文件到压缩列表"
    }

    private var deleteTooltip: String {
        if appState.mode == .browseArchive && !appState.isWritableArchive {
            return "当前压缩包为只读格式，不支持删除条目"
        }
        return appState.mode == .browseArchive ? "从压缩包中删除所选项目" : "从压缩列表移除所选项目"
    }

    private func chooseAndAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "添加"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let urls = panel.urls
            if appState.mode == .compress {
                appState.addEntries(from: urls)
            } else if appState.isWritableArchive {
                Task {
                    await appState.coordinator.addEntries(
                        appState: appState,
                        urls: urls,
                        progressState: progressState,
                        openWindow: openWindow
                    )
                }
            }
        }
    }
}
