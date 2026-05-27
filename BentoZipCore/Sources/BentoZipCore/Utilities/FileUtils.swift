import Foundation

enum FileUtils {
    /// Get the size of a file or directory.
    static func fileSize(at url: URL) -> Int64 {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if resourceValues?.isDirectory == true {
            return directorySize(at: url)
        }
        return Int64(resourceValues?.fileSize ?? 0)
    }

    /// Recursively compute the size of a directory.
    static func directorySize(at url: URL) -> Int64 {
        guard isDirectory(at: url) else { return 0 }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Get the modification date of a file.
    static func fileModificationDate(at url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Check if a URL represents a directory.
    static func isDirectory(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    /// Get the display name of a file.
    static func displayName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        return values?.localizedName ?? url.lastPathComponent
    }

    /// List the contents of a directory (URLs only, not recursive).
    static func enumerateDirectory(at url: URL) -> [URL] {
        guard isDirectory(at: url) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
