import Foundation

/// Encryption method used when creating password-protected ZIP archives.
public enum ZipEncryptionMethod: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
    case aes256 = "AES-256"
    case zipCrypto = "ZipCrypto"

    public var id: String { rawValue }

    public var bento7zValue: String {
        switch self {
        case .aes256: return "aes256"
        case .zipCrypto: return "zipcrypto"
        }
    }
}

/// Configuration for creating a new archive.
public struct CompressionSettings: Sendable, Equatable {
    public var format: ArchiveFormat = .zip
    public var compressionLevel: CompressionLevel = .normal
    public var archiveName: String = ""
    public var preserveDirectoryStructure: Bool = true
    public var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    public var password: String? = nil
    public var zipEncryptionMethod: ZipEncryptionMethod = .aes256
    /// Multi-volume split threshold in bytes (`0` creates a single archive). Supported for ZIP and 7z.
    public var volumeSizeBytes: Int64 = 0
    /// Encrypt archive file headers/filenames when supported (e.g. 7z).
    public var encryptHeaders: Bool = true
    /// Follow symbolic links and archive their targets instead of storing links.
    public var followSymlinks: Bool = false
    /// Compress each top-level input item into its own separate archive when multiple items are staged.
    public var compressEachSeparately: Bool = false

    public init(
        format: ArchiveFormat = .zip,
        compressionLevel: CompressionLevel = .normal,
        archiveName: String = "",
        preserveDirectoryStructure: Bool = true,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"],
        password: String? = nil,
        zipEncryptionMethod: ZipEncryptionMethod = .aes256,
        volumeSizeBytes: Int64 = 0,
        encryptHeaders: Bool = true,
        followSymlinks: Bool = false,
        compressEachSeparately: Bool = false
    ) {
        self.format = format
        self.compressionLevel = compressionLevel
        self.archiveName = archiveName
        self.preserveDirectoryStructure = preserveDirectoryStructure
        self.exclusionPatterns = exclusionPatterns
        self.password = password
        self.zipEncryptionMethod = zipEncryptionMethod
        self.volumeSizeBytes = volumeSizeBytes
        self.encryptHeaders = encryptHeaders
        self.followSymlinks = followSymlinks
        self.compressEachSeparately = compressEachSeparately
    }

    /// Return a copy with `format` updated and `archiveName` extension synchronized when appropriate.
    public func updatingFormat(to newFormat: ArchiveFormat) -> CompressionSettings {
        var copy = self
        let oldFormat = self.format
        copy.format = newFormat
        if !newFormat.supportsPassword {
            copy.password = nil
        }
        if !newFormat.supportsSplitVolumes {
            copy.volumeSizeBytes = 0
        }
        copy.archiveName = Self.archiveNameWithSyncedExtension(
            copy.archiveName,
            oldFormat: oldFormat,
            newFormat: newFormat
        )
        return copy
    }

    /// Synchronize an archive filename's extension when switching compression formats.
    public static func archiveNameWithSyncedExtension(
        _ currentName: String,
        oldFormat: ArchiveFormat,
        newFormat: ArchiveFormat
    ) -> String {
        let trimmed = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentName }

        let oldSuffix = "." + oldFormat.fileExtension
        let newSuffix = "." + newFormat.fileExtension
        let lowercased = trimmed.lowercased()

        if lowercased.hasSuffix(oldSuffix.lowercased()) {
            let stem = String(trimmed.dropLast(oldSuffix.count))
            return stem + newSuffix
        }

        // Match longest known suffix first so compound suffixes like `.tar.gz` take precedence over `.tar`.
        let knownSuffixes = ArchiveFormat.allCases
            .map { "." + $0.fileExtension.lowercased() }
            .sorted { $0.count > $1.count }

        if let matched = knownSuffixes.first(where: { lowercased.hasSuffix($0) }) {
            let stem = String(trimmed.dropLast(matched.count))
            return stem + newSuffix
        }

        if !trimmed.contains(".") {
            return trimmed + newSuffix
        }

        return trimmed
    }
}

/// Writable archive formats exposed in compression settings and UI pickers.
public enum ArchiveFormat: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
    case zip = "ZIP"
    case sevenZip = "7z"
    case tar = "TAR"
    case tarGz = "TAR.GZ"
    case tarBz2 = "TAR.BZ2"
    case tarXz = "TAR.XZ"
    case tarZstd = "TAR.ZST"
    case zstd = "ZSTD"
    case dmg = "DMG"
    case aar = "AAR"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tarZstd: return "tar.zst"
        case .zstd: return "zst"
        case .dmg: return "dmg"
        case .aar: return "aar"
        }
    }

    public var supportsPassword: Bool {
        self == .zip || self == .sevenZip
    }

    public var supportsSplitVolumes: Bool {
        self == .zip || self == .sevenZip
    }

    /// Format identifier expected by bento7z.
    public var bento7zFormatName: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tarZstd: return "tar.zst"
        case .zstd: return "zst"
        case .dmg: return "dmg"
        case .aar: return "aar"
        }
    }

    /// Resolve a persisted preference string into a writable `ArchiveFormat`, migrating legacy values.
    public static func fromPersistedValue(_ rawValue: String) -> ArchiveFormat? {
        if let exact = ArchiveFormat(rawValue: rawValue) {
            return exact
        }
        switch rawValue.uppercased() {
        case "BZ2", "BZIP2": return .tarBz2
        case "XZ": return .tarXz
        case "ZST", "ZSTD": return .zstd
        case "TAR.ZST", "TZST", "TAR.ZSTD": return .tarZstd
        case "DMG": return .dmg
        default: return nil
        }
    }
}

/// All archive formats supported for reading/browsing, including read-only formats such as RAR, Zstd, DMG, ISO, and split volumes.
public enum ReadableArchiveFormat: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case zip
    case sevenZip
    case tar
    case tarGz
    case gz
    case tarBz2
    case bz2
    case tarXz
    case xz
    case tarZst
    case zst
    case rar
    case dmg
    case iso
    case xar
    case cab
    case wim
    case cpio
    case lzma
    case deb
    case rpm
    case lzh
    case squashfs
    case vmdk
    case chm
    case arj
    case tarLz4
    case lz4
    case brotli
    case epub
    case split7z
    case splitZip
    case splitTar
    case splitRar
    case splitGeneric
    case aar

    public var id: String { rawValue }

    /// Human-readable format label for UI display.
    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7z"
        case .tar: return "TAR"
        case .tarGz: return "TAR.GZ"
        case .gz: return "GZIP"
        case .tarBz2: return "TAR.BZ2"
        case .bz2: return "BZ2"
        case .tarXz: return "TAR.XZ"
        case .xz: return "XZ"
        case .tarZst: return "TAR.ZST"
        case .zst: return "ZSTD"
        case .rar: return "RAR"
        case .dmg: return "DMG"
        case .iso: return "ISO"
        case .xar: return "XAR"
        case .cab: return "CAB"
        case .wim: return "WIM"
        case .cpio: return "CPIO"
        case .lzma: return "LZMA"
        case .deb: return "DEB"
        case .rpm: return "RPM"
        case .lzh: return "LZH"
        case .squashfs: return "SquashFS"
        case .vmdk: return "VMDK"
        case .chm: return "CHM"
        case .arj: return "ARJ"
        case .tarLz4: return "TAR.LZ4"
        case .lz4: return "LZ4"
        case .brotli: return "Brotli"
        case .epub: return "EPUB"
        case .split7z: return "7z (Split)"
        case .splitZip: return "ZIP (Split)"
        case .splitTar: return "TAR (Split)"
        case .splitRar: return "RAR (Split)"
        case .splitGeneric: return "Split Archive"
        case .aar: return "AAR"
        }
    }

    /// Corresponding writable format when archive modification/creation is supported.
    public var writableFormat: ArchiveFormat? {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tarGz: return .tarGz
        case .tarBz2: return .tarBz2
        case .tarXz: return .tarXz
        case .tarZst: return .tarZstd
        case .aar: return .aar
        case .gz, .bz2, .xz, .zst, .rar, .dmg, .iso, .xar,
             .cab, .wim, .cpio, .lzma, .deb, .rpm, .lzh,
             .squashfs, .vmdk, .chm, .arj, .tarLz4, .lz4, .brotli, .epub,
             .split7z, .splitZip, .splitTar, .splitRar, .splitGeneric:
            return nil
        }
    }

    public var isReadOnly: Bool {
        writableFormat == nil
    }

    /// Format hint passed to bento7z when opening the container.
    /// Single-stream compressed containers (`.gz`, `.bz2`, `.xz`, `.zst`, `.lz4`, `.br`) use `"auto"` so compound `.tar.*` streams unwrap cleanly.
    public var bento7zFormatName: String {
        switch self {
        case .zip, .splitZip, .epub: return "zip"
        case .sevenZip, .split7z: return "7z"
        case .tar, .splitTar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tarZst: return "tar.zst"
        case .tarLz4: return "tar.lz4"
        case .gz, .bz2, .xz, .zst, .lz4, .brotli: return "auto"
        case .rar, .splitRar: return "rar"
        case .dmg: return "dmg"
        case .iso: return "iso"
        case .xar: return "xar"
        case .cab: return "cab"
        case .wim: return "wim"
        case .cpio: return "cpio"
        case .lzma: return "lzma"
        case .deb: return "deb"
        case .rpm: return "rpm"
        case .lzh: return "lzh"
        case .squashfs: return "squashfs"
        case .vmdk: return "vmdk"
        case .chm: return "chm"
        case .arj: return "arj"
        case .splitGeneric: return "split"
        case .aar: return "aar"
        }
    }
}

/// Compression strength presets mapped to bento7z compression levels.
public enum CompressionLevel: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
    case none = "无压缩"
    case fast = "快速"
    case normal = "标准"
    case best = "最佳"

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .none: return String(localized: "Store", bundle: .module)
        case .fast: return String(localized: "Fast", bundle: .module)
        case .normal: return String(localized: "Normal", bundle: .module)
        case .best: return String(localized: "Best", bundle: .module)
        }
    }

    public var shortLocalizedName: String {
        switch self {
        case .none: return String(localized: "None", bundle: .module)
        case .fast: return String(localized: "Fast", bundle: .module)
        case .normal: return String(localized: "Normal", bundle: .module)
        case .best: return String(localized: "Best", bundle: .module)
        }
    }
}
