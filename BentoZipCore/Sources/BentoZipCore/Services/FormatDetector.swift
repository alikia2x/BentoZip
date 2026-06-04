import Foundation

public struct FormatDetector {
    public init() {}

    public static func detectFormat(of url: URL) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        // Double extensions
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .sevenZip  // bento7z handles tar.gz via auto-detection
        }
        switch ext {
        case "zip": return .zip
        case "7z": return .sevenZip
        case "gz": return .sevenZip  // bento7z handles gz via auto-detection
        default: break
        }

        // Magic byte detection
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 8) {
                // ZIP magic: PK\x03\x04
                if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
                    return .zip
                }
                // 7z magic: 7z\xBC\xAF
                if data.count >= 4 && data[0] == 0x37 && data[1] == 0x7A && data[2] == 0xBC && data[3] == 0xAF {
                    return .sevenZip
                }
                // gzip magic: \x1F\x8B
                if data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B {
                    return .sevenZip  // bento7z handles gzip/tar.gz via auto-detection
                }
            }
        }

        return nil
    }

    public static func isArchiveFile(_ url: URL) -> Bool {
        return detectFormat(of: url) != nil
    }
}
