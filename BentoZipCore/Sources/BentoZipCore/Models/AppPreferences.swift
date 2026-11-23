import Foundation
import SwiftData

@Model
public final class AppPreferences {
    public var defaultFormat: String = ArchiveFormat.zip.rawValue
    public var defaultCompressionLevel: String = CompressionLevel.normal.rawValue
    public var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    public var lastSaveDirectory: String? = nil
    public var recentArchives: [String] = []
    public var revealInFinderAfterExtract: Bool = true
    public var unwrapSingleTopDirectory: Bool = true

    public init(
        defaultFormat: String = ArchiveFormat.zip.rawValue,
        defaultCompressionLevel: String = CompressionLevel.normal.rawValue,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"],
        lastSaveDirectory: String? = nil,
        recentArchives: [String] = [],
        revealInFinderAfterExtract: Bool = true,
        unwrapSingleTopDirectory: Bool = true
    ) {
        self.defaultFormat = defaultFormat
        self.defaultCompressionLevel = defaultCompressionLevel
        self.exclusionPatterns = exclusionPatterns
        self.lastSaveDirectory = lastSaveDirectory
        self.recentArchives = recentArchives
        self.revealInFinderAfterExtract = revealInFinderAfterExtract
        self.unwrapSingleTopDirectory = unwrapSingleTopDirectory
    }
}
