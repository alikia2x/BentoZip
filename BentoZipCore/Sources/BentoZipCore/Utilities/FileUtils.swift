import Foundation

enum FileUtils {
    /// Get the size of a file or directory synchronously.
    static func fileSize(at url: URL) -> Int64 {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if resourceValues?.isDirectory == true {
            return directorySize(at: url)
        }
        return Int64(resourceValues?.fileSize ?? 0)
    }

    /// Recursively compute the size of a directory synchronously.
    static func directorySize(at url: URL) -> Int64 {
        guard isDirectory(at: url) else { return 0 }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
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

    /// List the immediate contents of a directory (non-recursive).
    static func enumerateDirectory(at url: URL) -> [URL] {
        guard isDirectory(at: url) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Build lightweight top-level entries immediately without recursive disk traversal.
    static func buildShallowEntries(from urls: [URL]) -> [FileEntry] {
        urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey])
            let isDir = values?.isDirectory == true
            return FileEntry(
                url: url,
                name: values?.localizedName ?? url.lastPathComponent,
                isDirectory: isDir,
                size: isDir ? 0 : Int64(values?.fileSize ?? 0),
                modificationDate: values?.contentModificationDate,
                isFromArchive: false,
                children: isDir ? [] : nil
            )
        }.sorted(by: entrySort)
    }

    /// Build full recursive FileEntry trees off the main actor with single-pass bottom-up size calculation.
    static func buildFileEntries(from urls: [URL]) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            var entries: [FileEntry] = []
            entries.reserveCapacity(urls.count)
            for url in urls {
                if Task.isCancelled { break }
                entries.append(buildEntrySync(for: url))
            }
            return entries.sorted(by: entrySort)
        }.value
    }

    private static func buildEntrySync(for url: URL) -> FileEntry {
        if Task.isCancelled {
            return FileEntry(url: url, name: displayName(for: url))
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey])
        let isDir = values?.isDirectory == true
        let name = values?.localizedName ?? url.lastPathComponent
        let modDate = values?.contentModificationDate

        if isDir {
            let childURLs = enumerateDirectory(at: url)
            var children: [FileEntry] = []
            children.reserveCapacity(childURLs.count)
            var totalSize: Int64 = 0
            for childURL in childURLs {
                if Task.isCancelled { break }
                let child = buildEntrySync(for: childURL)
                totalSize += child.size
                children.append(child)
            }
            children.sort(by: entrySort)
            return FileEntry(
                url: url,
                name: name,
                isDirectory: true,
                size: totalSize,
                modificationDate: modDate,
                isFromArchive: false,
                children: children
            )
        } else {
            return FileEntry(
                url: url,
                name: name,
                isDirectory: false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: modDate,
                isFromArchive: false,
                children: nil
            )
        }
    }

    private static func entrySort(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
