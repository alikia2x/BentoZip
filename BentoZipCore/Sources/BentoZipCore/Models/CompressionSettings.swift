import Foundation

public struct CompressionSettings {
    public var format: ArchiveFormat = .zip
    public var compressionLevel: CompressionLevel = .normal
    public var archiveName: String = ""
    public var preserveDirectoryStructure: Bool = true
    public var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    // Reserved for future:
    // var password: String? = nil
    // var splitVolumeSize: Int64? = nil

    public init(
        format: ArchiveFormat = .zip,
        compressionLevel: CompressionLevel = .normal,
        archiveName: String = "",
        preserveDirectoryStructure: Bool = true,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    ) {
        self.format = format
        self.compressionLevel = compressionLevel
        self.archiveName = archiveName
        self.preserveDirectoryStructure = preserveDirectoryStructure
        self.exclusionPatterns = exclusionPatterns
    }
}

public enum ArchiveFormat: String, CaseIterable, Identifiable {
    case sevenZip = "7z"
    case zip = "ZIP"
    case tar = "TAR"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .sevenZip: return "7z"
        case .zip: return "zip"
        case .tar: return "tar"
        }
    }
}

public enum CompressionLevel: String, CaseIterable, Identifiable {
    case none = "无压缩"
    case fast = "快速"
    case normal = "标准"
    case best = "最佳"

    public var id: String { rawValue }
}
