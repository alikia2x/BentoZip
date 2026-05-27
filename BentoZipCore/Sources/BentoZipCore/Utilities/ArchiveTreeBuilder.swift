import Foundation

/// Builds a hierarchical tree of FileEntry from flat archive entry paths.
/// Both ZIPEngine and LibArchiveReader use this to produce consistent directory trees.
enum ArchiveTreeBuilder {

    /// A flat entry description used as input for tree building.
    public struct FlatEntry {
        public let path: String       // Full path within the archive, e.g. "dir/subdir/file.txt"
        public let name: String      // Display name (filename only)
        public let isDirectory: Bool
        public let size: Int64
        public let modificationDate: Date?

        public init(path: String, name: String, isDirectory: Bool, size: Int64, modificationDate: Date? = nil) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.modificationDate = modificationDate
        }
    }

    /// Build a tree of FileEntry from flat entries.
    /// Entries are organized into directories based on their paths.
    /// Directory entries are created automatically for intermediate paths that don't have explicit entries.
    /// The resulting entries have their `children` properly set for navigation.
    public static func build(from flatEntries: [FlatEntry]) -> [FileEntry] {
        // Intermediate tree node using reference semantics for easy mutation
        final class Node {
            let name: String
            let relativePath: String  // Full path within archive (e.g. "dir/subdir")
            var isDirectory: Bool
            var size: Int64
            var modificationDate: Date?
            var children: [String: Node] = [:]  // Keyed by path component name

            init(name: String, relativePath: String, isDirectory: Bool, size: Int64 = 0, modificationDate: Date? = nil) {
                self.name = name
                self.relativePath = relativePath
                self.isDirectory = isDirectory
                self.size = size
                self.modificationDate = modificationDate
            }
        }

        let root = Node(name: "", relativePath: "", isDirectory: true)

        for entry in flatEntries {
            let path = entry.path
            guard !path.isEmpty else { continue }

            let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { continue }

            // Navigate to parent, creating intermediate directories as needed
            var current = root
            for i in 0..<(components.count - 1) {
                let dirName = components[i]
                if current.children[dirName] == nil {
                    let dirPath = components[0...i].joined(separator: "/")
                    current.children[dirName] = Node(name: dirName, relativePath: dirPath, isDirectory: true)
                }
                current = current.children[dirName]!
            }

            // Add the leaf entry
            let leafName = components.last!
            let leafPath = path
            let displayName = entry.name.isEmpty ? leafName : entry.name

            if let existingNode = current.children[leafName] {
                // Node already exists (e.g., a directory that was created as an intermediate)
                // Update with actual entry data
                existingNode.isDirectory = entry.isDirectory
                existingNode.size = entry.size
                existingNode.modificationDate = entry.modificationDate
                // Preserve the display name if the original entry has a better one
                if !entry.name.isEmpty {
                    // Use overwrite via removing and re-adding to update key
                    // Actually name stays the same key, just update properties
                }
            } else {
                current.children[leafName] = Node(
                    name: displayName,
                    relativePath: leafPath,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modificationDate: entry.modificationDate
                )
            }
        }

        // Convert the Node tree back to FileEntry array with proper children
        func convert(node: Node) -> [FileEntry] {
            var result: [FileEntry] = []
            for (_, child) in node.children {
                let children = child.isDirectory ? convert(node: child) : nil
                let entry = FileEntry(
                    url: URL(fileURLWithPath: "/archive-root/" + child.relativePath),
                    name: child.name,
                    isDirectory: child.isDirectory,
                    size: child.size,
                    modificationDate: child.modificationDate,
                    isFromArchive: true,
                    children: children
                )
                result.append(entry)
            }
            return result.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        func unwrapSingleDirectory(_ entries: [FileEntry]) -> [FileEntry] {
            if entries.count == 1, let first = entries.first, first.isDirectory, let children = first.children {
                return unwrapSingleDirectory(children)
            }
            return entries
        }

        return unwrapSingleDirectory(convert(node: root))
    }
}