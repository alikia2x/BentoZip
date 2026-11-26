import Foundation

/// Creates `.zst` and `.tar.zst` archives using an available `zstd` executable
/// (bundled in `Contents/Helpers/zstd` or installed via Homebrew/system paths).
public struct ZstdEngine: Sendable {
    public init() {}

    /// Locate a usable `zstd` executable on the system, preferring a bundled helper if present.
    public static func findZstdBinary() -> String? {
        let fm = FileManager.default
        let candidates: [String] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zstd").path,
            Bundle.main.url(forResource: "zstd", withExtension: nil)?.path,
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd"
        ].compactMap { $0 }

        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static var isAvailable: Bool {
        findZstdBinary() != nil
    }

    public func createZstd(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        guard let zstdBinary = Self.findZstdBinary() else {
            throw Bento7zError.operationFailed(
                String(
                    localized: "Zstandard (.zst) compression requires the zstd binary. Install zstd (e.g. brew install zstd) to create .zst archives.",
                    bundle: .module
                ),
                "UNSUPPORTED_FORMAT"
            )
        }

        guard sourceURLs.count == 1, let sourceURL = sourceURLs.first else {
            throw Bento7zError.operationFailed(
                String(
                    localized: "Single-file .zst compression only supports one file. Choose TAR.ZST (.tar.zst) for multiple items or folders.",
                    bundle: .module
                ),
                "UNSUPPORTED_FORMAT"
            )
        }

        let status = Bento7zPathSafety.itemStatus(at: sourceURL)
        guard status.exists else {
            throw Bento7zError.fileNotFound(sourceURL.path)
        }
        guard !status.isDirectory else {
            throw Bento7zError.operationFailed(
                String(
                    localized: "Folders cannot be compressed directly into a single .zst stream. Choose TAR.ZST (.tar.zst) instead.",
                    bundle: .module
                ),
                "UNSUPPORTED_FORMAT"
            )
        }

        let fm = FileManager.default
        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }

        let levelFlag = "-\(Self.zstdLevel(for: settings.compressionLevel))"
        onProgress(ArchiveProgress(fractionCompleted: 0.1, currentFile: sourceURL.lastPathComponent))

        do {
            try await DiskImageEngine.runSubprocess(
                executablePath: zstdBinary,
                arguments: [levelFlag, "-f", "-q", "-o", archiveURL.path, sourceURL.path]
            )
            try Task.checkCancellation()
            onProgress(ArchiveProgress(fractionCompleted: 1.0, currentFile: archiveURL.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    public func createTarZstd(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        tarBuilder: Bento7zEngine,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        guard let zstdBinary = Self.findZstdBinary() else {
            throw Bento7zError.operationFailed(
                String(
                    localized: "Zstandard (.tar.zst) compression requires the zstd binary. Install zstd (e.g. brew install zstd) to create .tar.zst archives.",
                    bundle: .module
                ),
                "UNSUPPORTED_FORMAT"
            )
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("BentoZip_tarzst_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tempTarURL = tempDir.appendingPathComponent("payload.tar")
        var tarSettings = settings
        tarSettings.format = .tar
        tarSettings.compressionLevel = .none
        tarSettings.password = nil
        tarSettings.volumeSizeBytes = 0

        try await tarBuilder.create(from: sourceURLs, to: tempTarURL, settings: tarSettings) { progress in
            let scaled = min(max(progress.fractionCompleted, 0.0), 1.0) * 0.65
            onProgress(ArchiveProgress(
                fractionCompleted: scaled,
                currentFile: progress.currentFile,
                processedBytes: progress.processedBytes,
                totalBytes: progress.totalBytes,
                isFileEvent: progress.isFileEvent,
                fileCountDelta: progress.fileCountDelta,
                stage: progress.stage
            ))
        }
        try Task.checkCancellation()

        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }

        let levelFlag = "-\(Self.zstdLevel(for: settings.compressionLevel))"
        onProgress(ArchiveProgress(fractionCompleted: 0.7, currentFile: archiveURL.lastPathComponent))

        do {
            try await DiskImageEngine.runSubprocess(
                executablePath: zstdBinary,
                arguments: [levelFlag, "-f", "-q", "-o", archiveURL.path, tempTarURL.path]
            )
            try Task.checkCancellation()
            onProgress(ArchiveProgress(fractionCompleted: 1.0, currentFile: archiveURL.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    private static func zstdLevel(for level: CompressionLevel) -> Int {
        switch level {
        case .none: return 1
        case .fast: return 1
        case .normal: return 3
        case .best: return 19
        }
    }
}
