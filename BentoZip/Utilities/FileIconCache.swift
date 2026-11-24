import AppKit
import BentoZipCore
import UniformTypeIdentifiers

@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: FileNode) -> NSImage {
        icon(isDirectory: node.isDirectory, url: node.url, isFromArchive: node.isFromArchive)
    }

    static func icon(for entry: FileEntry) -> NSImage {
        icon(isDirectory: entry.isDirectory, url: entry.url, isFromArchive: entry.isFromArchive)
    }

    static func icon(forFileAt path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "__archive__" : "file:\(ext)"
        return cachedIcon(key: key) {
            NSWorkspace.shared.icon(forFile: path)
        }
    }

    private static func icon(isDirectory: Bool, url: URL, isFromArchive: Bool) -> NSImage {
        if isDirectory {
            return cachedIcon(key: "__folder__") {
                NSWorkspace.shared.icon(for: .folder)
            }
        }

        let ext = url.pathExtension.lowercased()
        if !isFromArchive, ext == "app" {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        let key = ext.isEmpty ? "__data__" : ext
        return cachedIcon(key: key) {
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
    }

    private static func cachedIcon(key: String, make: () -> NSImage) -> NSImage {
        if let existing = cache[key] {
            return existing
        }
        let image = make()
        cache[key] = image
        return image
    }
}
