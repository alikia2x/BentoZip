import AppKit
import FinderSync
import UniformTypeIdentifiers

final class FinderSyncController: FIFinderSync {
    private static let hostBundleIdentifier = "com.alikia.bentozip"

    private static let singleArchiveExtensions: Set<String> = [
        "zip", "zipx", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz4",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "zst", "zstd", "lz4", "br",
        "aar", "yaa", "dmg", "iso", "xar", "pkg", "cab", "wim", "cpio",
        "deb", "rpm", "lzh", "lha", "squashfs", "sfs", "vmdk", "chm", "arj",
        "epub", "cbz", "cbr"
    ]

    private static let compoundArchiveSuffixes: [String] = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4",
        ".7z.001", ".zip.001", ".tar.001"
    ]

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override var toolbarItemName: String {
        String(localized: "BentoZip")
    }

    override var toolbarItemToolTip: String {
        String(localized: "Compress or extract selected items with BentoZip")
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "archivebox", accessibilityDescription: "BentoZip")
            ?? NSImage(named: NSImage.actionTemplateName)
            ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "BentoZip")
        let selectedURLs = selectedTargetURLs(for: menuKind)
        guard !selectedURLs.isEmpty else { return menu }

        let compressItem = NSMenuItem(
            title: String(localized: "Compress with BentoZip"),
            action: #selector(compressSelected(_:)),
            keyEquivalent: ""
        )
        compressItem.target = self
        menu.addItem(compressItem)

        let containsArchive = selectedURLs.contains(where: Self.looksLikeArchiveURL(_:))
        if containsArchive {
            let extractItem = NSMenuItem(
                title: String(localized: "Extract Here"),
                action: #selector(extractSelectedHere(_:)),
                keyEquivalent: ""
            )
            extractItem.target = self
            menu.addItem(extractItem)

            let browseItem = NSMenuItem(
                title: String(localized: "Browse in BentoZip"),
                action: #selector(browseSelected(_:)),
                keyEquivalent: ""
            )
            browseItem.target = self
            menu.addItem(browseItem)
        }

        return menu
    }

    @objc private func compressSelected(_ sender: Any?) {
        let urls = activeTargetURLs()
        guard !urls.isEmpty else { return }
        openInHostApp(action: "compress", urls: urls)
    }

    @objc private func extractSelectedHere(_ sender: Any?) {
        let archives = activeTargetURLs().filter(Self.looksLikeArchiveURL(_:))
        guard !archives.isEmpty else { return }
        openInHostApp(action: "extract", urls: archives)
    }

    @objc private func browseSelected(_ sender: Any?) {
        let archives = activeTargetURLs().filter(Self.looksLikeArchiveURL(_:))
        guard !archives.isEmpty else { return }
        openInHostApp(action: "browse", urls: archives)
    }

    // MARK: - Helpers

    private func selectedTargetURLs(for menuKind: FIMenuKind) -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if menuKind == .contextualMenuForContainer, let target = controller.targetedURL() {
            return [target]
        }
        return []
    }

    private func activeTargetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let target = controller.targetedURL() {
            return [target]
        }
        return []
    }

    private func openInHostApp(action: String, urls: [URL]) {
        var components = URLComponents()
        components.scheme = "bentozip"
        components.host = action
        var queryItems = urls.map { URLQueryItem(name: "path", value: $0.standardizedFileURL.path) }
        if let token = Self.readIPCToken() {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = queryItems

        let config = NSWorkspace.OpenConfiguration()
        config.activates = (action != "extract")

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.hostBundleIdentifier) {
            if let actionURL = components.url {
                NSWorkspace.shared.open([actionURL], withApplicationAt: appURL, configuration: config)
            } else {
                NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
            }
        } else if let actionURL = components.url {
            NSWorkspace.shared.open(actionURL)
        }
    }

    private static func readIPCToken() -> String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let tokenURL = appSupport
            .appendingPathComponent("BentoZip", isDirectory: true)
            .appendingPathComponent(".ipc-token", isDirectory: false)
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func looksLikeArchiveURL(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else {
            return false
        }
        let lowerName = url.lastPathComponent.lowercased()
        if compoundArchiveSuffixes.contains(where: { lowerName.hasSuffix($0) }) {
            return true
        }
        if lowerName.hasSuffix(".rar"), lowerName.contains(".part") {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if singleArchiveExtensions.contains(ext) {
            return true
        }
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext), utType.conforms(to: .archive) {
            return true
        }
        return ext.count == 3 && ext.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
