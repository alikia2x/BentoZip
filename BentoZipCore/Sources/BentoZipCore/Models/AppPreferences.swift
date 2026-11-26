import Foundation
import SwiftData

/// Action performed when opening an archive from Finder or the Open panel.
public enum ArchiveOpenAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case browse = "browse"
    case extract = "extract"

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .browse: return String(localized: "Browse Archive", bundle: .module)
        case .extract: return String(localized: "Extract Directly", bundle: .module)
        }
    }
}

/// Destination strategy used during direct archive extraction.
public enum ExtractDestinationMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case sameFolder = "sameFolder"
    case customFolder = "customFolder"
    case askEveryTime = "askEveryTime"

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .sameFolder: return String(localized: "Same Folder as Archive", bundle: .module)
        case .customFolder: return String(localized: "Custom Folder", bundle: .module)
        case .askEveryTime: return String(localized: "Ask Every Time", bundle: .module)
        }
    }
}

/// Policy applied when an extracted file or item collides with an existing destination item.
public enum ExtractConflictPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask = "ask"
    case overwrite = "overwrite"
    case skip = "skip"
    case rename = "rename"

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .ask: return String(localized: "Ask", bundle: .module)
        case .overwrite: return String(localized: "Overwrite", bundle: .module)
        case .skip: return String(localized: "Skip", bundle: .module)
        case .rename: return String(localized: "Keep Both (Rename)", bundle: .module)
        }
    }
}

/// Character encoding option used when decoding legacy archive entry filenames.
public enum FilenameEncodingOption: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto = "auto"
    case utf8 = "UTF-8"
    case gb18030 = "GB18030"
    case big5 = "BIG5"
    case shiftJIS = "SHIFT_JIS"
    case eucKR = "EUC-KR"
    case cp437 = "CP437"
    case windows1252 = "WINDOWS-1252"
    case windows1251 = "WINDOWS-1251"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto Detect", bundle: .module)
        case .utf8: return "UTF-8"
        case .gb18030: return String(localized: "Simplified Chinese (GB18030)", bundle: .module)
        case .big5: return String(localized: "Traditional Chinese (Big5)", bundle: .module)
        case .shiftJIS: return String(localized: "Japanese (Shift-JIS)", bundle: .module)
        case .eucKR: return String(localized: "Korean (EUC-KR)", bundle: .module)
        case .cp437: return String(localized: "DOS / OEM (CP437)", bundle: .module)
        case .windows1252: return String(localized: "Western European (Windows-1252)", bundle: .module)
        case .windows1251: return String(localized: "Cyrillic (Windows-1251)", bundle: .module)
        }
    }

    /// Name passed to `bento7z` (`iconv`) or `nil` for automatic detection.
    public var iconvName: String? {
        self == .auto ? nil : rawValue
    }
}

@Model
public final class AppPreferences {
    public var defaultFormat: String = ArchiveFormat.zip.rawValue
    public var defaultCompressionLevel: String = CompressionLevel.normal.rawValue
    public var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    public var lastSaveDirectory: String? = nil
    public var recentArchives: [String] = []
    public var revealInFinderAfterExtract: Bool = true
    public var unwrapSingleTopDirectory: Bool = true
    public var maxCacheSizeMB: Int = 2048
    public var archiveOpenAction: String = ArchiveOpenAction.browse.rawValue
    public var extractDestinationMode: String = ExtractDestinationMode.sameFolder.rawValue
    public var customExtractDirectory: String? = nil
    public var extractConflictPolicy: String = ExtractConflictPolicy.ask.rawValue
    public var moveArchiveToTrashAfterExtract: Bool = false
    public var closeWindowAfterExtract: Bool = false
    public var showHiddenFiles: Bool = false
    public var sortColumnKey: String = "name"
    public var sortAscending: Bool = true

    public init(
        defaultFormat: String = ArchiveFormat.zip.rawValue,
        defaultCompressionLevel: String = CompressionLevel.normal.rawValue,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"],
        lastSaveDirectory: String? = nil,
        recentArchives: [String] = [],
        revealInFinderAfterExtract: Bool = true,
        unwrapSingleTopDirectory: Bool = true,
        maxCacheSizeMB: Int = 2048,
        archiveOpenAction: String = ArchiveOpenAction.browse.rawValue,
        extractDestinationMode: String = ExtractDestinationMode.sameFolder.rawValue,
        customExtractDirectory: String? = nil,
        extractConflictPolicy: String = ExtractConflictPolicy.ask.rawValue,
        moveArchiveToTrashAfterExtract: Bool = false,
        closeWindowAfterExtract: Bool = false,
        showHiddenFiles: Bool = false,
        sortColumnKey: String = "name",
        sortAscending: Bool = true
    ) {
        self.defaultFormat = defaultFormat
        self.defaultCompressionLevel = defaultCompressionLevel
        self.exclusionPatterns = exclusionPatterns
        self.lastSaveDirectory = lastSaveDirectory
        self.recentArchives = recentArchives
        self.revealInFinderAfterExtract = revealInFinderAfterExtract
        self.unwrapSingleTopDirectory = unwrapSingleTopDirectory
        self.maxCacheSizeMB = maxCacheSizeMB
        self.archiveOpenAction = archiveOpenAction
        self.extractDestinationMode = extractDestinationMode
        self.customExtractDirectory = customExtractDirectory
        self.extractConflictPolicy = extractConflictPolicy
        self.moveArchiveToTrashAfterExtract = moveArchiveToTrashAfterExtract
        self.closeWindowAfterExtract = closeWindowAfterExtract
        self.showHiddenFiles = showHiddenFiles
        self.sortColumnKey = sortColumnKey
        self.sortAscending = sortAscending
    }
}
