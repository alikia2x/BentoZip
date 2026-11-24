import Foundation

/// Single-source-of-truth reference tree node for local files and archive entries.
/// Designed for O(1) in-place mutations and direct use as `NSOutlineView` items.
@MainActor
public final class FileNode: Identifiable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var size: Int64 {
        didSet {
            if isFromArchive && size != oldValue {
                parent?.recomputeArchiveSubtreeSize()
            }
        }
    }
    public let packedSize: Int64?
    public let modificationDate: Date?
    public let isEncrypted: Bool
    public let isFromArchive: Bool
    public let archiveRelativePath: String?
    public weak var parent: FileNode?
    public var children: [FileNode]? {
        didSet {
            if isFromArchive && isDirectory {
                recomputeArchiveSubtreeSize()
            }
        }
    }
    public var hasLoadedChildren: Bool
    private var cachedArchiveSubtreeSize: Int64?

    /// Whether this node can be disclosed in an outline view.
    public var isExpandable: Bool {
        isDirectory && ((!isFromArchive && !hasLoadedChildren) || !(children ?? []).isEmpty)
    }

    /// Returns cached subtree byte size for archive directories in O(1), or `size` for files and local directories.
    public var archiveTotalSize: Int64 {
        if isFromArchive, isDirectory, let cachedArchiveSubtreeSize {
            return cachedArchiveSubtreeSize
        }
        return size
    }

    private func recomputeArchiveSubtreeSize() {
        guard isFromArchive, isDirectory else { return }
        let updated = children?.reduce(Int64(0)) { $0 + $1.archiveTotalSize }
        guard updated != cachedArchiveSubtreeSize else { return }
        cachedArchiveSubtreeSize = updated
        parent?.recomputeArchiveSubtreeSize()
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        packedSize: Int64? = nil,
        modificationDate: Date? = nil,
        isEncrypted: Bool = false,
        isFromArchive: Bool = false,
        archiveRelativePath: String? = nil,
        parent: FileNode? = nil,
        children: [FileNode]? = nil,
        hasLoadedChildren: Bool? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
        self.isFromArchive = isFromArchive
        self.archiveRelativePath = archiveRelativePath
        self.parent = parent
        self.children = children
        self.hasLoadedChildren = hasLoadedChildren ?? (!isDirectory || isFromArchive || children != nil)
        if isFromArchive, isDirectory, let children {
            self.cachedArchiveSubtreeSize = children.reduce(Int64(0)) { $0 + $1.archiveTotalSize }
        }
    }

    /// Recursively converts a `FileEntry` value tree into a `FileNode` reference tree with `parent` links.
    public convenience init(entry: FileEntry, parent: FileNode? = nil) {
        self.init(
            id: entry.id,
            url: entry.url,
            name: entry.name,
            isDirectory: entry.isDirectory,
            size: entry.size,
            packedSize: entry.packedSize,
            modificationDate: entry.modificationDate,
            isEncrypted: entry.isEncrypted,
            isFromArchive: entry.isFromArchive,
            archiveRelativePath: entry.archiveRelativePath,
            parent: parent,
            children: nil,
            hasLoadedChildren: entry.hasLoadedChildren
        )
        if let entryChildren = entry.children {
            self.children = entryChildren.map { FileNode(entry: $0, parent: self) }
            recomputeArchiveSubtreeSize()
        }
    }

    /// Returns a `FileEntry` snapshot for engine and drag-drop calls.
    /// Defaults to a lightweight snapshot without deep-copying children.
    public func toFileEntry(includeChildren: Bool = false) -> FileEntry {
        FileEntry(
            id: id,
            url: url,
            name: name,
            isDirectory: isDirectory,
            size: size,
            packedSize: packedSize,
            modificationDate: modificationDate,
            isEncrypted: isEncrypted,
            isFromArchive: isFromArchive,
            archiveRelativePath: archiveRelativePath,
            children: includeChildren ? children?.map { $0.toFileEntry(includeChildren: true) } : nil,
            hasLoadedChildren: hasLoadedChildren
        )
    }
}
