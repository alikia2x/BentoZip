import Foundation

public struct FormatDetector {
    public init() {}

    public static func detectFormat(of url: URL) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tarGz
        }
        switch ext {
        case "zip": return .zip
        case "7z": return .sevenZip
        case "gz": return .tarGz
        default: break
        }

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 8) {
                if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
                    return .zip
                }
                if data.count >= 4 && data[0] == 0x37 && data[1] == 0x7A && data[2] == 0xBC && data[3] == 0xAF {
                    return .sevenZip
                }
                if data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B {
                    return .tarGz
                }
            }
        }

        return nil
    }

    public static func isArchiveFile(_ url: URL) -> Bool {
        return detectFormat(of: url) != nil
    }
}
