import Foundation

public struct FileEntry: Identifiable, Hashable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    public let isFromArchive: Bool
    public var children: [FileEntry]?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modificationDate: Date? = nil,
        isFromArchive: Bool = false,
        children: [FileEntry]? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isFromArchive = isFromArchive
        self.children = children
    }
}
