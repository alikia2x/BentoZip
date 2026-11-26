import CryptoKit
import Foundation

/// Cryptographic digest pair computed for a local or extracted archive file.
public struct FileChecksums: Sendable, Equatable {
    public let sha256: String
    public let md5: String

    public init(sha256: String, md5: String) {
        self.sha256 = sha256
        self.md5 = md5
    }
}

/// Streaming off-main-actor cryptographic hash helpers.
public enum FileHashUtils {
    private static let chunkSize = 1_048_576 // 1 MiB

    /// Compute lowercase hex SHA-256 and MD5 checksums for `fileURL` using streaming reads off `@MainActor`.
    public static func computeHashes(for fileURL: URL) async throws -> FileChecksums {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try computeHashesSync(for: fileURL)
        }.value
    }

    private static func computeHashesSync(for fileURL: URL) throws -> FileChecksums {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var sha256 = SHA256()
        var md5 = Insecure.MD5()

        while true {
            try Task.checkCancellation()
            let chunk: Data? = try autoreleasepool {
                try handle.read(upToCount: chunkSize)
            }
            guard let data = chunk, !data.isEmpty else {
                break
            }
            sha256.update(data: data)
            md5.update(data: data)
        }

        let shaDigest = sha256.finalize()
        let md5Digest = md5.finalize()
        return FileChecksums(
            sha256: hexString(shaDigest),
            md5: hexString(md5Digest)
        )
    }

    private static func hexString<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
