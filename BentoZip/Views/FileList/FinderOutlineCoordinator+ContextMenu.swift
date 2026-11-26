import AppKit
import BentoZipCore
import UniformTypeIdentifiers

private final class OpenWithPayload: NSObject {
    let node: FileNode
    let appURL: URL

    init(node: FileNode, appURL: URL) {
        self.node = node
        self.appURL = appURL
    }
}

extension FinderOutlineCoordinator {

    func makeContextMenu(for targets: [FileNode]) -> NSMenu? {
        let isBusy = appState.isLoading || progressState.isOperationInProgress

        if targets.isEmpty {
            guard appState.isWritableArchive else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(makeMenuItem(
                title: String(localized: "New Folder…"),
                action: #selector(contextNewFolder(_:)),
                targets: [],
                isEnabled: !isBusy
            ))
            return menu
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        var hasPrimarySection = false
        if targets.count == 1, let node = targets.first {
            menu.addItem(makeMenuItem(
                title: String(localized: "Open"),
                action: #selector(contextOpen(_:)),
                targets: [node]
            ))

            if !node.isDirectory, let openWithItem = makeOpenWithMenuItem(for: node) {
                menu.addItem(openWithItem)
            }

            if !node.isDirectory || !node.isFromArchive {
                menu.addItem(makeMenuItem(
                    title: String(localized: "Quick Look"),
                    action: #selector(contextQuickLook(_:)),
                    targets: [node]
                ))
            }
            hasPrimarySection = true
        } else if targets.contains(where: { !$0.isDirectory || !$0.isFromArchive }) {
            menu.addItem(makeMenuItem(
                title: String(localized: "Quick Look"),
                action: #selector(contextQuickLook(_:)),
                targets: targets
            ))
            hasPrimarySection = true
        }

        if appState.mode == .browseArchive {
            if hasPrimarySection {
                menu.addItem(.separator())
            }
            menu.addItem(makeMenuItem(
                title: String(localized: "Extract Selected Here"),
                action: #selector(contextExtractSelectedHere(_:)),
                targets: targets,
                isEnabled: !isBusy
            ))
            menu.addItem(makeMenuItem(
                title: String(localized: "Extract Selected…"),
                action: #selector(contextExtractSelected(_:)),
                targets: targets,
                isEnabled: !isBusy
            ))
        }

        if appState.mode == .compress {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            if targets.count == 1 {
                menu.addItem(makeMenuItem(
                    title: String(localized: "Show in Finder"),
                    action: #selector(contextShowInFinder(_:)),
                    targets: targets
                ))
            }
            menu.addItem(makeMenuItem(
                title: String(localized: "Remove"),
                action: #selector(contextRemove(_:)),
                targets: targets,
                isEnabled: !isBusy
            ))
        } else if appState.isWritableArchive {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            if targets.count == 1 {
                menu.addItem(makeMenuItem(
                    title: String(localized: "Rename…"),
                    action: #selector(contextRename(_:)),
                    targets: targets,
                    isEnabled: !isBusy
                ))
            }
            menu.addItem(makeMenuItem(
                title: String(localized: "New Folder…"),
                action: #selector(contextNewFolder(_:)),
                targets: targets,
                isEnabled: !isBusy
            ))
            menu.addItem(makeMenuItem(
                title: String(localized: "Delete…"),
                action: #selector(contextDeleteFromArchive(_:)),
                targets: targets,
                isEnabled: !isBusy
            ))
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let copyNamesTitle = targets.count == 1
            ? String(localized: "Copy Name")
            : String(localized: "Copy Names")
        let copyNamesItem = makeMenuItem(
            title: copyNamesTitle,
            action: #selector(contextCopyNames(_:)),
            targets: targets,
            keyEquivalent: "c",
            modifiers: [.command]
        )
        menu.addItem(copyNamesItem)

        let copyPathsTitle = targets.count == 1
            ? String(localized: "Copy Path")
            : String(localized: "Copy Paths")
        let copyPathsItem = makeMenuItem(
            title: copyPathsTitle,
            action: #selector(contextCopyPaths(_:)),
            targets: targets,
            keyEquivalent: "c",
            modifiers: [.command, .option]
        )
        menu.addItem(copyPathsItem)

        return menu.items.isEmpty ? nil : menu
    }

    private func makeOpenWithMenuItem(for node: FileNode) -> NSMenuItem? {
        let workspace = NSWorkspace.shared
        let appURLs: [URL]
        let defaultAppURL: URL?

        if !node.isFromArchive, FileManager.default.fileExists(atPath: node.url.path) {
            appURLs = workspace.urlsForApplications(toOpen: node.url)
            defaultAppURL = workspace.urlForApplication(toOpen: node.url)
        } else {
            let ext = node.url.pathExtension
            let utType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            appURLs = workspace.urlsForApplications(toOpen: utType)
            defaultAppURL = workspace.urlForApplication(toOpen: utType)
        }

        guard !appURLs.isEmpty else { return nil }

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        var uniqueURLs: [URL] = []
        var seenPaths = Set<String>()
        if let defaultAppURL, seenPaths.insert(defaultAppURL.standardizedFileURL.path).inserted {
            uniqueURLs.append(defaultAppURL)
        }
        let sortedOthers = appURLs.sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: $1.path)) == .orderedAscending
        }
        for appURL in sortedOthers {
            if seenPaths.insert(appURL.standardizedFileURL.path).inserted {
                uniqueURLs.append(appURL)
            }
        }

        for (index, appURL) in uniqueURLs.enumerated() {
            var title = FileManager.default.displayName(atPath: appURL.path)
            if title.hasSuffix(".app") {
                title = String(title.dropLast(4))
            }
            if index == 0, defaultAppURL?.standardizedFileURL == appURL.standardizedFileURL {
                title = String(localized: "\(title) (default)")
            }

            let item = NSMenuItem(
                title: title,
                action: #selector(contextOpenWith(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = OpenWithPayload(node: node, appURL: appURL)
            let icon = workspace.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)

            if index == 0, defaultAppURL?.standardizedFileURL == appURL.standardizedFileURL, uniqueURLs.count > 1 {
                submenu.addItem(.separator())
            }
        }

        let parentItem = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        parentItem.submenu = submenu
        return parentItem
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        targets: [FileNode],
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = targets
        item.isEnabled = isEnabled
        return item
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode],
              let first = nodes.first else { return }
        openNode(first)
    }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? OpenWithPayload else { return }
        openNode(payload.node, withApplicationAt: payload.appURL)
    }

    @objc private func contextQuickLook(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode] else { return }
        previewNodes(nodes)
    }

    @objc private func contextExtractSelectedHere(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress,
              let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        let entries = nodes.map { $0.toFileEntry() }
        Task {
            await appState.coordinator.extract(
                appState: appState,
                progressState: progressState,
                entries: entries,
                chooseDestination: false
            )
        }
    }

    @objc private func contextExtractSelected(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress,
              let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        let entries = nodes.map { $0.toFileEntry() }
        Task {
            await appState.coordinator.extract(
                appState: appState,
                progressState: progressState,
                entries: entries,
                chooseDestination: true
            )
        }
    }

    @objc private func contextShowInFinder(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode],
              let first = nodes.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([first.url])
    }

    @objc private func contextRemove(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress,
              let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        appState.removeNodes(nodes)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress,
              let nodes = sender.representedObject as? [FileNode],
              nodes.count == 1,
              let first = nodes.first else { return }
        uiState.renameTargetEntry = first.toFileEntry()
    }

    @objc private func contextNewFolder(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress else { return }
        uiState.showNewFolderSheet = true
    }

    @objc private func contextDeleteFromArchive(_ sender: NSMenuItem) {
        guard !appState.isLoading, !progressState.isOperationInProgress,
              let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        onRequestArchiveDelete(nodes.map { $0.toFileEntry() })
    }

    @objc private func contextCopyNames(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        copyNames(nodes)
    }

    @objc private func contextCopyPaths(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        copyPaths(nodes)
    }
}
