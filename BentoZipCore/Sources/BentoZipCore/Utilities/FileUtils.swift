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
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Compute a directory's total byte size off the main actor without allocating `FileEntry` trees.
    static func computeDirectorySizeAsync(at url: URL) async -> Int64? {
        await Task.detached(priority: .utility) {
            computeDirectorySizeSync(at: url)
        }.value
    }

    private static func computeDirectorySizeSync(at url: URL) -> Int64? {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Int64(0)
        }
        var visited = 0
        for case let fileURL as URL in enumerator {
            visited &+= 1
            if (visited & 0xFF) == 0, Task.isCancelled {
                return nil
            }
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return Task.isCancelled ? nil : total
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

    /// Build lightweight top-level entries off the main actor without recursive disk traversal.
    static func buildShallowEntriesAsync(from urls: [URL]) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            buildShallowEntries(from: urls)
        }.value
    }

    /// Build lightweight top-level entries immediately without recursive disk traversal.
    /// Local directories start with `children = nil` and `hasLoadedChildren = false` so they load lazily on expansion.
    static func buildShallowEntries(from urls: [URL]) -> [FileEntry] {
        urls.map { makeShallowEntry(for: $0) }.sorted(by: entrySort)
    }

    /// Load only the immediate (1-level) children of a local directory off the main actor.
    static func loadImmediateChildrenAsync(of directoryURL: URL) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) {
            readImmediateChildren(of: directoryURL)
        }.value
    }

    private static func readImmediateChildren(of directoryURL: URL) -> [FileEntry] {
        guard isDirectory(at: directoryURL) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .map { makeShallowEntry(for: $0) }
            .sorted(by: entrySort)
    }

    private static func makeShallowEntry(for url: URL) -> FileEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey])
        let isDir = values?.isDirectory == true
        return FileEntry(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            isDirectory: isDir,
            size: isDir ? 0 : Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            isFromArchive: false,
            children: nil,
            hasLoadedChildren: !isDir
        )
    }

    private static func entrySort(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
