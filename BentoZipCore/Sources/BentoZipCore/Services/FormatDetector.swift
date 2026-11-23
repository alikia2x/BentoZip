import Foundation

/// Detects archive formats by compound extension, single extension, and magic bytes.
public struct FormatDetector {
    public init() {}

    /// Detect any readable archive format (including read-only formats like RAR).
    public static func detectReadableFormat(of url: URL) -> ReadableArchiveFormat? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return nil
        }

        let name = url.lastPathComponent.lowercased()
        if let compound = detectByCompoundExtension(fileName: name) {
            return compound
        }

        let ext = url.pathExtension.lowercased()
        if let single = detectBySingleExtension(ext) {
            return single
        }

        return detectByMagicBytes(at: url)
    }

    /// Detect a writable archive format corresponding to the given URL.
    public static func detectFormat(of url: URL) -> ArchiveFormat? {
        detectReadableFormat(of: url)?.writableFormat
    }

    /// Return `true` when the URL refers to any supported readable archive.
    public static func isArchiveFile(_ url: URL) -> Bool {
        detectReadableFormat(of: url) != nil
    }

    // MARK: - Private Helpers

    private static func detectByCompoundExtension(fileName: String) -> ReadableArchiveFormat? {
        if fileName.hasSuffix(".tar.gz") || fileName.hasSuffix(".tgz") {
            return .tarGz
        }
        if fileName.hasSuffix(".tar.bz2") || fileName.hasSuffix(".tbz2") || fileName.hasSuffix(".tbz") {
            return .tarBz2
        }
        if fileName.hasSuffix(".tar.xz") || fileName.hasSuffix(".txz") {
            return .tarXz
        }
        return nil
    }

    private static func detectBySingleExtension(_ ext: String) -> ReadableArchiveFormat? {
        switch ext {
        case "zip", "zipx": return .zip
        case "7z": return .sevenZip
        case "tar": return .tar
        case "gz", "gzip": return .gz
        case "bz2", "bzip2": return .bz2
        case "xz": return .xz
        case "rar": return .rar
        default: return nil
        }
    }

    private static func detectByMagicBytes(at url: URL) -> ReadableArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 265), !data.isEmpty else { return nil }

        let bytes = [UInt8](data)

        // ZIP: PK\x03\x04 (local file), PK\x05\x06 (empty EOCD), PK\x07\x08 (spanned)
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B {
            if (bytes[2] == 0x03 && bytes[3] == 0x04)
                || (bytes[2] == 0x05 && bytes[3] == 0x06)
                || (bytes[2] == 0x07 && bytes[3] == 0x08) {
                return .zip
            }
        }

        // 7z: 7z\xBC\xAF\x27\x1C
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) {
            return .sevenZip
        }

        // RAR: Rar!\x1A\x07 (v4/v5) or Rar!
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) || bytes.starts(with: [0x52, 0x61, 0x72, 0x21]) {
            return .rar
        }

        // XZ: \xFD7zXZ\x00
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return .xz
        }

        // BZ2: BZh
        if bytes.starts(with: [0x42, 0x5A, 0x68]) {
            return .bz2
        }

        // GZIP: \x1F\x8B
        if bytes.starts(with: [0x1F, 0x8B]) {
            return .gz
        }

        // TAR: "ustar" at offset 257
        if bytes.count >= 262 {
            let tarMagic = Array(bytes[257..<262])
            if tarMagic == [0x75, 0x73, 0x74, 0x61, 0x72] {
                return .tar
            }
        }

        return nil
    }
}
