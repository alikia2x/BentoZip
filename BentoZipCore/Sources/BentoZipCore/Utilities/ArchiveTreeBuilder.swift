import Foundation

/// Builds a hierarchical tree of `FileEntry` values from flat archive entry paths.
public enum ArchiveTreeBuilder {

    /// A flat entry description produced by listing an archive.
    public struct FlatEntry: Sendable {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let packedSize: Int64?
        public let modificationDate: Date?
        public let isEncrypted: Bool

        public init(
            path: String,
            name: String,
            isDirectory: Bool,
            size: Int64,
            packedSize: Int64? = nil,
            modificationDate: Date? = nil,
            isEncrypted: Bool = false
        ) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.packedSize = packedSize
            self.modificationDate = modificationDate
            self.isEncrypted = isEncrypted
        }
    }

    /// Build a sorted tree of `FileEntry` from flat entries, creating intermediate directories as needed.
    public static func build(from flatEntries: [FlatEntry]) -> [FileEntry] {
        final class Node {
            var name: String
            var relativePath: String
            var archivePath: String
            var isDirectory: Bool
            var size: Int64
            var packedSize: Int64?
            var modificationDate: Date?
            var isEncrypted: Bool
            var children: [String: Node] = [:]

            init(
                name: String,
                relativePath: String,
                archivePath: String,
                isDirectory: Bool,
                size: Int64 = 0,
                packedSize: Int64? = nil,
                modificationDate: Date? = nil,
                isEncrypted: Bool = false
            ) {
                self.name = name
                self.relativePath = relativePath
                self.archivePath = archivePath
                self.isDirectory = isDirectory
                self.size = size
                self.packedSize = packedSize
                self.modificationDate = modificationDate
                self.isEncrypted = isEncrypted
            }
        }

        let root = Node(name: "", relativePath: "", archivePath: "", isDirectory: true)

        for entry in flatEntries {
            let normalized = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.isEmpty,
                  !normalized.hasPrefix("/"),
                  !normalized.contains("\0") else {
                continue
            }
            // Reject Windows drive prefixes (e.g. C:/...) that could escape root.
            if normalized.count >= 2,
               let firstChar = normalized.first, firstChar.isLetter,
               normalized[normalized.index(after: normalized.startIndex)] == ":" {
                continue
            }

            var components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.contains("..") else { continue }
            while components.first == "." {
                components.removeFirst()
            }
            guard !components.isEmpty else { continue }

            let candidateRootURL = URL(fileURLWithPath: "/archive-root/" + components.joined(separator: "/"))
            guard candidateRootURL.standardizedFileURL.path.hasPrefix("/archive-root/") else {
                continue
            }

            var current = root
            for i in 0..<(components.count - 1) {
                let dirName = components[i]
                if current.children[dirName] == nil {
                    let dirPath = components[0...i].joined(separator: "/")
                    current.children[dirName] = Node(
                        name: dirName,
                        relativePath: dirPath,
                        archivePath: dirPath,
                        isDirectory: true
                    )
                }
                current = current.children[dirName]!
            }

            let leafName = components.last!
            let leafRelativePath = components.joined(separator: "/")
            let displayName = Self.sanitizedDisplayName(entry.name, fallback: leafName)

            if let existingNode = current.children[leafName] {
                if !entry.name.isEmpty {
                    existingNode.name = displayName
                }
                existingNode.archivePath = entry.path
                existingNode.isDirectory = entry.isDirectory
                existingNode.size = entry.size
                existingNode.packedSize = entry.packedSize
                existingNode.modificationDate = entry.modificationDate
                existingNode.isEncrypted = entry.isEncrypted
            } else {
                current.children[leafName] = Node(
                    name: displayName,
                    relativePath: leafRelativePath,
                    archivePath: entry.path,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    packedSize: entry.packedSize,
                    modificationDate: entry.modificationDate,
                    isEncrypted: entry.isEncrypted
                )
            }
        }

        func convert(node: Node) -> [FileEntry] {
            var result: [FileEntry] = []
            result.reserveCapacity(node.children.count)
            for (_, child) in node.children {
                let children = child.isDirectory ? convert(node: child) : nil
                let entry = FileEntry(
                    url: URL(fileURLWithPath: "/archive-root/" + child.relativePath),
                    name: child.name,
                    isDirectory: child.isDirectory,
                    size: child.size,
                    packedSize: child.packedSize,
                    modificationDate: child.modificationDate,
                    isEncrypted: child.isEncrypted,
                    isFromArchive: true,
                    archiveRelativePath: child.archivePath,
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

    private static func sanitizedDisplayName(_ rawName: String, fallback: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".." else {
            return fallback
        }
        return trimmed
    }
}
