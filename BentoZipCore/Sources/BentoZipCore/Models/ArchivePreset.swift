import Foundation

/// Reusable compression preset storing archive format, strength, encryption, split, and filtering options.
public struct ArchivePreset: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var format: ArchiveFormat
    public var compressionLevel: CompressionLevel
    public var zipEncryptionMethod: ZipEncryptionMethod
    public var encryptHeaders: Bool
    public var volumeSizeBytes: Int64
    public var preserveDirectoryStructure: Bool
    public var followSymlinks: Bool
    public var compressEachSeparately: Bool
    public var exclusionPatterns: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        format: ArchiveFormat = .zip,
        compressionLevel: CompressionLevel = .normal,
        zipEncryptionMethod: ZipEncryptionMethod = .aes256,
        encryptHeaders: Bool = true,
        volumeSizeBytes: Int64 = 0,
        preserveDirectoryStructure: Bool = true,
        followSymlinks: Bool = false,
        compressEachSeparately: Bool = false,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.compressionLevel = compressionLevel
        self.zipEncryptionMethod = zipEncryptionMethod
        self.encryptHeaders = encryptHeaders
        self.volumeSizeBytes = volumeSizeBytes
        self.preserveDirectoryStructure = preserveDirectoryStructure
        self.followSymlinks = followSymlinks
        self.compressEachSeparately = compressEachSeparately
        self.exclusionPatterns = exclusionPatterns
    }

    /// Create a preset snapshot from the current `CompressionSettings`.
    public init(
        id: UUID = UUID(),
        name: String,
        settings: CompressionSettings
    ) {
        self.init(
            id: id,
            name: name,
            format: settings.format,
            compressionLevel: settings.compressionLevel,
            zipEncryptionMethod: settings.zipEncryptionMethod,
            encryptHeaders: settings.encryptHeaders,
            volumeSizeBytes: settings.volumeSizeBytes,
            preserveDirectoryStructure: settings.preserveDirectoryStructure,
            followSymlinks: settings.followSymlinks,
            compressEachSeparately: settings.compressEachSeparately,
            exclusionPatterns: settings.exclusionPatterns
        )
    }

    public static let builtInDefaults: [ArchivePreset] = [
        ArchivePreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
            name: "Clean ZIP",
            format: .zip,
            compressionLevel: .normal,
            zipEncryptionMethod: .aes256,
            encryptHeaders: true,
            volumeSizeBytes: 0,
            preserveDirectoryStructure: true,
            followSymlinks: false,
            compressEachSeparately: false,
            exclusionPatterns: [
                ".DS_Store",
                "__MACOSX",
                "._*",
                ".Spotlight-V100",
                ".Trashes",
                "Thumbs.db",
                "desktop.ini"
            ]
        ),
        ArchivePreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002") ?? UUID(),
            name: "Encrypted 7z (500 MB Split)",
            format: .sevenZip,
            compressionLevel: .best,
            zipEncryptionMethod: .aes256,
            encryptHeaders: true,
            volumeSizeBytes: 500 * 1024 * 1024,
            preserveDirectoryStructure: true,
            followSymlinks: false,
            compressEachSeparately: false,
            exclusionPatterns: [".DS_Store", "__MACOSX"]
        )
    ]
}
