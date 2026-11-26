import Foundation

/// Represents a local file/directory or an entry inside an archive.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var size: Int64
    public let packedSize: Int64?
    public let modificationDate: Date?
    public let crc: UInt32?
    public let isEncrypted: Bool
    public let isFromArchive: Bool
    public let archiveRelativePath: String?
    public var children: [FileEntry]?
    public var hasLoadedChildren: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        packedSize: Int64? = nil,
        modificationDate: Date? = nil,
        crc: UInt32? = nil,
        isEncrypted: Bool = false,
        isFromArchive: Bool = false,
        archiveRelativePath: String? = nil,
        children: [FileEntry]? = nil,
        hasLoadedChildren: Bool? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modificationDate = modificationDate
        self.crc = crc
        self.isEncrypted = isEncrypted
        self.isFromArchive = isFromArchive
        self.archiveRelativePath = archiveRelativePath
        self.children = children
        self.hasLoadedChildren = hasLoadedChildren ?? (!isDirectory || isFromArchive || children != nil)
    }
}
