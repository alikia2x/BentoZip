import AppKit
import BentoZipCore

extension FinderOutlineCoordinator {

    func makeContextMenu(for targets: [FileNode]) -> NSMenu? {
        guard !targets.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        var hasPrimarySection = false
        if targets.count == 1, let node = targets.first {
            if node.isDirectory {
                menu.addItem(makeMenuItem(
                    title: String(localized: "Open"),
                    action: #selector(contextOpen(_:)),
                    targets: [node]
                ))
                if !node.isFromArchive {
                    menu.addItem(makeMenuItem(
                        title: String(localized: "Quick Look"),
                        action: #selector(contextQuickLook(_:)),
                        targets: [node]
                    ))
                }
            } else {
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

        var secondaryItems: [NSMenuItem] = []

        if appState.mode == .browseArchive {
            secondaryItems.append(makeMenuItem(
                title: String(localized: "Extract Selected…"),
                action: #selector(contextExtractSelected(_:)),
                targets: targets
            ))
        }

        if appState.mode == .compress, targets.count == 1 {
            secondaryItems.append(makeMenuItem(
                title: String(localized: "Show in Finder"),
                action: #selector(contextShowInFinder(_:)),
                targets: targets
            ))
        }

        if appState.mode == .compress {
            let removable = targets.filter { $0.parent == nil }
            if !removable.isEmpty {
                secondaryItems.append(makeMenuItem(
                    title: String(localized: "Remove"),
                    action: #selector(contextRemove(_:)),
                    targets: removable
                ))
            }
        } else if appState.isWritableArchive {
            secondaryItems.append(makeMenuItem(
                title: String(localized: "Delete…"),
                action: #selector(contextDeleteFromArchive(_:)),
                targets: targets
            ))
        }

        if !secondaryItems.isEmpty {
            if hasPrimarySection {
                menu.addItem(.separator())
            }
            secondaryItems.forEach { menu.addItem($0) }
        }

        if targets.count == 1 {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(makeMenuItem(
                title: String(localized: "Copy Path"),
                action: #selector(contextCopyPath(_:)),
                targets: targets
            ))
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func makeMenuItem(title: String, action: Selector, targets: [FileNode]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = targets
        return item
    }

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode],
              let first = nodes.first else { return }
        appState.navigateInto(first)
    }

    @objc private func contextQuickLook(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode] else { return }
        previewNodes(nodes)
    }

    @objc private func contextExtractSelected(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
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
        guard let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        appState.removeNodes(nodes)
    }

    @objc private func contextDeleteFromArchive(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode], !nodes.isEmpty else { return }
        onRequestArchiveDelete(nodes.map { $0.toFileEntry() })
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let nodes = sender.representedObject as? [FileNode],
              let first = nodes.first else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(first.archiveRelativePath ?? first.url.path, forType: .string)
    }
}
