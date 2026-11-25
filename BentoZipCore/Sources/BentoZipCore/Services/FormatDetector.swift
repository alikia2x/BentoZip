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
        if fileName.hasSuffix(".tar.zst") || fileName.hasSuffix(".tzst") {
            return .tarZst
        }
        if let split = detectSplitVolumeExtension(fileName: fileName) {
            return split
        }
        return nil
    }

    private static func detectSplitVolumeExtension(fileName: String) -> ReadableArchiveFormat? {
        // Multi-part RAR: .part1.rar, .part01.rar, .part2.rar, etc.
        if fileName.hasSuffix(".rar"),
           let dotPart = fileName.range(of: ".part", options: [.backwards]) {
            let digitsStart = dotPart.upperBound
            let digitsEnd = fileName.index(fileName.endIndex, offsetBy: -4)
            if digitsStart < digitsEnd {
                let digits = fileName[digitsStart..<digitsEnd]
                if digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) {
                    return .splitRar
                }
            }
        }

        // Numbered split volumes: .7z.001, .zip.001, .tar.001, .001 (and secondary .002..999)
        if let dot = fileName.lastIndex(of: ".") {
            let ext = fileName[fileName.index(after: dot)...]
            if ext.count >= 3 && ext.allSatisfy({ $0.isASCII && $0.isNumber }) {
                let stem = String(fileName[..<dot])
                if stem.hasSuffix(".7z") { return .split7z }
                if stem.hasSuffix(".zip") { return .splitZip }
                if stem.hasSuffix(".tar") { return .splitTar }
                return .splitGeneric
            }
            if ext.count == 3 && ext.first == "r" && ext.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) {
                return .splitRar
            }
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
        case "zst", "zstd": return .zst
        case "rar": return .rar
        case "dmg": return .dmg
        case "iso": return .iso
        case "xar", "pkg": return .xar
        case "cab": return .cab
        case "wim": return .wim
        case "cpio": return .cpio
        case "lzma": return .lzma
        case "deb": return .deb
        case "rpm": return .rpm
        case "lzh", "lha": return .lzh
        case "aar", "yaa": return .aar
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

        // Zstandard: 28 B5 2F FD
        if bytes.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            return .zst
        }

        // BZ2: BZh
        if bytes.starts(with: [0x42, 0x5A, 0x68]) {
            return .bz2
        }

        // GZIP: \x1F\x8B
        if bytes.starts(with: [0x1F, 0x8B]) {
            return .gz
        }

        // Apple Archive: "YAA1", "AA01", or compressed AA stream ("pbz4"/"pbze"/"pbzl"/"pbzx")
        if bytes.starts(with: [0x59, 0x41, 0x41, 0x31])
            || bytes.starts(with: [0x41, 0x41, 0x30, 0x31])
            || (bytes.count >= 4 && bytes[0] == 0x70 && bytes[1] == 0x62 && bytes[2] == 0x7A
                && (bytes[3] == 0x34 || bytes[3] == 0x65 || bytes[3] == 0x6C || bytes[3] == 0x78)) {
            return .aar
        }

        // XAR: "xar!"
        if bytes.starts(with: [0x78, 0x61, 0x72, 0x21]) {
            return .xar
        }

        // CAB: "MSCF"
        if bytes.starts(with: [0x4D, 0x53, 0x43, 0x46]) {
            return .cab
        }

        // WIM: "MSWIM\0\0\0"
        if bytes.starts(with: [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00]) {
            return .wim
        }

        // RPM: ED AB EE DB
        if bytes.starts(with: [0xED, 0xAB, 0xEE, 0xDB]) {
            return .rpm
        }

        // DEB / ar: "!<arch>\n"
        if bytes.starts(with: [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A]) {
            return .deb
        }

        // TAR: "ustar" at offset 257
        if bytes.count >= 262 {
            let tarMagic = Array(bytes[257..<262])
            if tarMagic == [0x75, 0x73, 0x74, 0x61, 0x72] {
                return .tar
            }
        }

        // ISO 9660: "CD001" at byte offset 0x8001 (32769)
        if (try? handle.seek(toOffset: 0x8001)) != nil,
           let isoMagic = try? handle.read(upToCount: 5),
           isoMagic.count == 5,
           [UInt8](isoMagic) == [0x43, 0x44, 0x30, 0x30, 0x31] {
            return .iso
        }

        return nil
    }
}
