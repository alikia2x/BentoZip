import Foundation

/// Configuration for creating a new archive.
public struct CompressionSettings: Sendable, Equatable {
    public var format: ArchiveFormat = .zip
    public var compressionLevel: CompressionLevel = .normal
    public var archiveName: String = ""
    public var preserveDirectoryStructure: Bool = true
    public var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    public var password: String? = nil

    public init(
        format: ArchiveFormat = .zip,
        compressionLevel: CompressionLevel = .normal,
        archiveName: String = "",
        preserveDirectoryStructure: Bool = true,
        exclusionPatterns: [String] = [".DS_Store", "__MACOSX"],
        password: String? = nil
    ) {
        self.format = format
        self.compressionLevel = compressionLevel
        self.archiveName = archiveName
        self.preserveDirectoryStructure = preserveDirectoryStructure
        self.exclusionPatterns = exclusionPatterns
        self.password = password
    }

    /// Return a copy with `format` updated and `archiveName` extension synchronized when appropriate.
    public func updatingFormat(to newFormat: ArchiveFormat) -> CompressionSettings {
        var copy = self
        let oldFormat = self.format
        copy.format = newFormat
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
public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case zip = "ZIP"
    case sevenZip = "7z"
    case tar = "TAR"
    case tarGz = "TAR.GZ"
    case tarBz2 = "TAR.BZ2"
    case tarXz = "TAR.XZ"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
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
        default: return nil
        }
    }
}

/// All archive formats supported for reading/browsing, including read-only formats such as RAR.
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
    case rar

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
        case .rar: return "RAR"
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
        case .gz, .bz2, .xz, .rar: return nil
        }
    }

    public var isReadOnly: Bool {
        writableFormat == nil
    }

    /// Format hint passed to bento7z when opening the container.
    /// Single-stream compressed containers (`.gz`, `.bz2`, `.xz`) use `"auto"` so compound `.tar.*` streams unwrap cleanly.
    public var bento7zFormatName: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .gz, .bz2, .xz: return "auto"
        case .rar: return "rar"
        }
    }
}

/// Compression strength presets mapped to bento7z compression levels.
public enum CompressionLevel: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case none = "无压缩"
    case fast = "快速"
    case normal = "标准"
    case best = "最佳"

    public var id: String { rawValue }
}
