import AppKit
import BentoZipCore
import UniformTypeIdentifiers

@MainActor
enum FileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: FileEntry) -> NSImage {
        if entry.isDirectory {
            return cachedIcon(key: "__folder__") {
                NSWorkspace.shared.icon(for: .folder)
            }
        }

        let ext = entry.url.pathExtension.lowercased()
        if !entry.isFromArchive, ext == "app" {
            return NSWorkspace.shared.icon(forFile: entry.url.path)
        }

        let key = ext.isEmpty ? "__data__" : ext
        return cachedIcon(key: key) {
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
    }

    static func icon(forFileAt path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "__archive__" : "file:\(ext)"
        return cachedIcon(key: key) {
            NSWorkspace.shared.icon(forFile: path)
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
