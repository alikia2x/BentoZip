import Foundation

/// Async non-blocking CLI stream fallback for `.lz4`, `.tar.lz4`, and `.br` (Brotli) archives,
/// which are not bundled in standard `7z.so`.
public struct ExternalStreamEngine: Sendable {
    public init() {}

    /// Locate an executable CLI helper, preferring `Contents/Helpers/` before Homebrew and system paths.
    public static func findBinary(named name: String) -> String? {
        let fm = FileManager.default
        let candidates: [String] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            Bundle.main.url(forResource: name, withExtension: nil)?.path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ].compactMap { $0 }

        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func findLz4Binary() -> String? {
        findBinary(named: "lz4")
    }

    public static func findBrotliBinary() -> String? {
        findBinary(named: "brotli")
    }

    public static func handles(_ format: ReadableArchiveFormat?) -> Bool {
        switch format {
        case .lz4, .tarLz4, .brotli:
            return true
        default:
            return false
        }
    }

    // MARK: - List

    func listArchive(
        in archiveURL: URL,
        format: ReadableArchiveFormat,
        unwrapSingleTopDirectory: Bool,
        tarEngine: Bento7zEngine,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        let attrs = try? fm.attributesOfItem(atPath: archiveURL.path)
        let packedSize = (attrs?[.size] as? NSNumber)?.int64Value
        let modDate = attrs?[.modificationDate] as? Date

        if format == .tarLz4 {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("BentoZip_tarlz4_list_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let tempTarURL = tempDir.appendingPathComponent("payload.tar")
            onProgress?(ArchiveProgress(
                fractionCompleted: 0.15,
                currentFile: archiveURL.lastPathComponent,
                stage: .unpackingOuter
            ))
            try await decompressStream(format: .tarLz4, from: archiveURL, to: tempTarURL)
            try Task.checkCancellation()

            let tarResult = try await tarEngine.listArchive(
                in: tempTarURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: unwrapSingleTopDirectory,
                onProgress: onProgress
            )
            return ArchiveListResult(
                entries: tarResult.entries,
                archivePackedSize: packedSize,
                unwrappedRootPath: tarResult.unwrappedRootPath,
                archiveComment: tarResult.archiveComment
            )
        }

        // Single-stream `.lz4` or `.br`: validate tool presence up front for clear error reporting.
        _ = try resolveDecoderBinary(for: format)

        let innerName = Self.singleStreamInnerName(for: archiveURL)
        let flatEntry = ArchiveTreeBuilder.FlatEntry(
            path: innerName,
            name: innerName,
            isDirectory: false,
            size: 0,
            packedSize: packedSize,
            modificationDate: modDate,
            isEncrypted: false
        )
        let built = ArchiveTreeBuilder.buildTreeWithMetadata(
            from: [flatEntry],
            archiveURL: archiveURL,
            unwrapSingleTopDirectory: unwrapSingleTopDirectory
        )
        onProgress?(ArchiveProgress(fractionCompleted: 1.0, currentFile: innerName))
        return ArchiveListResult(
            entries: built.entries,
            archivePackedSize: packedSize,
            unwrappedRootPath: built.unwrappedRootPath
        )
    }

    // MARK: - Extract

    func extract(
        archiveURL: URL,
        format: ReadableArchiveFormat,
        entries: [FileEntry]?,
        to destinationURL: URL,
        tarEngine: Bento7zEngine,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        if format == .tarLz4 {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("BentoZip_tarlz4_ext_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let tempTarURL = tempDir.appendingPathComponent("payload.tar")
            onProgress(ArchiveProgress(
                fractionCompleted: 0.15,
                currentFile: archiveURL.lastPathComponent,
                stage: .unpackingOuter
            ))
            try await decompressStream(format: .tarLz4, from: archiveURL, to: tempTarURL)
            try Task.checkCancellation()

            try await tarEngine.extract(
                archiveURL: tempTarURL,
                entries: entries,
                to: destinationURL,
                password: nil,
                encoding: nil
            ) { progress in
                let scaled = 0.35 + min(max(progress.fractionCompleted, 0.0), 1.0) * 0.65
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
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        let innerName = Self.singleStreamInnerName(for: archiveURL)
        let outputURL = try Bento7zPathSafety.verifiedDescendantURL(
            relativePath: innerName,
            baseDirectory: destinationURL
        )
        onProgress(ArchiveProgress(fractionCompleted: 0.1, currentFile: innerName))
        try await decompressStream(format: format, from: archiveURL, to: outputURL)
        try Task.checkCancellation()
        onProgress(ArchiveProgress(fractionCompleted: 1.0, currentFile: innerName))
    }

    func extractEntry(
        from archiveURL: URL,
        format: ReadableArchiveFormat,
        entryPath: String,
        to destinationURL: URL,
        tarEngine: Bento7zEngine
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default

        if format == .tarLz4 {
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("BentoZip_tarlz4_entry_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let tempTarURL = tempDir.appendingPathComponent("payload.tar")
            try await decompressStream(format: .tarLz4, from: archiveURL, to: tempTarURL)
            try Task.checkCancellation()
            try await tarEngine.extractEntry(
                from: tempTarURL,
                entryPath: entryPath,
                to: destinationURL
            )
            return
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if Bento7zPathSafety.itemExists(at: destinationURL) {
            try fm.removeItem(at: destinationURL)
        }
        try await decompressStream(format: format, from: archiveURL, to: destinationURL)
    }

    // MARK: - Test

    func testArchive(
        at archiveURL: URL,
        format: ReadableArchiveFormat,
        tarEngine: Bento7zEngine,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveTestResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("BentoZip_stream_test_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let decodedURL = tempDir.appendingPathComponent(format == .tarLz4 ? "payload.tar" : "payload.bin")
        onProgress?(ArchiveProgress(fractionCompleted: 0.2, currentFile: archiveURL.lastPathComponent))
        try await decompressStream(format: format, from: archiveURL, to: decodedURL)
        try Task.checkCancellation()

        if format == .tarLz4 {
            return try await tarEngine.testArchive(at: decodedURL, password: nil, onProgress: onProgress)
        }

        onProgress?(ArchiveProgress(fractionCompleted: 1.0, currentFile: archiveURL.lastPathComponent))
        return ArchiveTestResult(itemsCount: 1)
    }

    // MARK: - Internals

    private func resolveDecoderBinary(for format: ReadableArchiveFormat) throws -> (path: String, isBrotli: Bool) {
        switch format {
        case .lz4, .tarLz4:
            guard let binary = Self.findLz4Binary() else {
                throw Bento7zError.operationFailed(
                    String(
                        localized: "LZ4 decompression requires the lz4 binary. Install lz4 (e.g. brew install lz4) to open .lz4 archives.",
                        bundle: .module
                    ),
                    "MISSING_TOOL"
                )
            }
            return (binary, false)
        case .brotli:
            guard let binary = Self.findBrotliBinary() else {
                throw Bento7zError.operationFailed(
                    String(
                        localized: "Brotli decompression requires the brotli binary. Install brotli (e.g. brew install brotli) to open .br archives.",
                        bundle: .module
                    ),
                    "MISSING_TOOL"
                )
            }
            return (binary, true)
        default:
            throw Bento7zError.operationFailed(
                String(localized: "Unsupported external stream format.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }
    }

    private func decompressStream(
        format: ReadableArchiveFormat,
        from sourceURL: URL,
        to outputURL: URL
    ) async throws {
        let resolved = try resolveDecoderBinary(for: format)
        let arguments: [String]
        if resolved.isBrotli {
            arguments = ["-d", "-f", sourceURL.path, "-o", outputURL.path]
        } else {
            arguments = ["-d", "-f", "-q", sourceURL.path, outputURL.path]
        }

        do {
            try await DiskImageEngine.runSubprocess(executablePath: resolved.path, arguments: arguments)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func singleStreamInnerName(for archiveURL: URL) -> String {
        let stem = archiveURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != ".", stem != ".." else {
            return "extracted"
        }
        return stem
    }
}
