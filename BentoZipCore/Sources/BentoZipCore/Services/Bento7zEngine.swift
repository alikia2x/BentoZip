import Foundation
import os

/// Archive engine communicating with the `bento7z` helper.
/// Uses the full-async multiplexed binary Unix Domain Socket server (`bento7z --server`) for real
/// `bento7z` binaries (persistent interactive worker for listing/Quick Look/drag-out + isolated
/// per-task binary workers for heavy compress/extract/update jobs), while automatically falling back
/// to JSONL stdio for shell-script test doubles.
public struct Bento7zEngine: ArchiveEngine, Sendable {

    let runner: Bento7zProcessRunner
    let cacheManager: ArchiveCacheManager

    public init(
        binaryPath: String? = nil,
        libraryPath: String? = nil,
        cacheManager: ArchiveCacheManager = .shared
    ) {
        self.runner = Bento7zProcessRunner(binaryPath: binaryPath, libraryPath: libraryPath)
        self.cacheManager = cacheManager
    }

    /// Gracefully shut down any persistent interactive binary workers (called on app termination).
    public static func shutdownInteractiveWorkers() {
        Bento7zInteractiveWorkerPool.shared.shutdownAll()
    }

    var prefersBinaryServer: Bool {
        !Self.isScriptExecutable(at: runner.binaryPath)
    }

    // MARK: - ArchiveEngine Protocol

    public func listEntries(in archiveURL: URL, password: String? = nil) async throws -> [FileEntry] {
        try await listArchive(in: archiveURL, password: password, onProgress: nil).entries
    }

    public func listArchive(in archiveURL: URL, password: String? = nil) async throws -> ArchiveListResult {
        try await listArchive(in: archiveURL, password: password, onProgress: nil)
    }

    public func listArchive(
        in archiveURL: URL,
        password: String? = nil,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        if FormatDetector.detectReadableFormat(of: archiveURL) == .aar {
            return try await AppleArchiveEngine().listArchive(in: archiveURL, onProgress: onProgress)
        }

        if prefersBinaryServer {
            return try await listArchiveBinary(in: archiveURL, password: password, onProgress: onProgress)
        }
        return try await listArchiveJSONL(in: archiveURL, password: password, onProgress: onProgress)
    }

    public func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String? = nil,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        if FormatDetector.detectReadableFormat(of: archiveURL) == .aar {
            try await AppleArchiveEngine().extract(
                archiveURL: archiveURL,
                entries: entries,
                to: destinationURL,
                onProgress: onProgress
            )
            return
        }

        if prefersBinaryServer {
            try await extractBinary(
                archiveURL: archiveURL,
                entries: entries,
                to: destinationURL,
                password: password,
                onProgress: onProgress
            )
            return
        }

        var params: [String: Any] = [
            "archive": archiveURL.path,
            "output": destinationURL.path
        ]
        if let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName {
            params["format"] = formatHint
        }
        if let password, !password.isEmpty {
            params["password"] = password
        }
        if let entries, !entries.isEmpty {
            let entryPaths = Bento7zPathSafety.collectArchivePaths(from: entries)
            if !entryPaths.isEmpty {
                params["entries"] = entryPaths
            }
        }

        let mapper = ProgressStageMapper(context: .extract)
        _ = try await runner.execute(command: "extract", params: params) { progress in
            onProgress(mapper.map(progress))
        }
        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    public func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        let fm = FileManager.default
        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }
        if settings.volumeSizeBytes > 0 {
            Self.cleanupSplitVolumes(baseArchiveURL: archiveURL)
        }

        if settings.format == .aar {
            do {
                try await AppleArchiveEngine().create(
                    from: sourceURLs,
                    to: archiveURL,
                    settings: settings,
                    onProgress: onProgress
                )
                return
            } catch {
                try? fm.removeItem(at: archiveURL)
                throw error
            }
        }

        do {
            if prefersBinaryServer {
                try await compressBinary(
                    from: sourceURLs,
                    to: archiveURL,
                    formatName: settings.format.bento7zFormatName,
                    settings: settings,
                    onProgress: onProgress
                )
            } else {
                try await executeDirectCompressJSONL(
                    from: sourceURLs,
                    to: archiveURL,
                    formatName: settings.format.bento7zFormatName,
                    settings: settings,
                    onProgress: onProgress
                )
            }
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
        } catch {
            try? fm.removeItem(at: archiveURL)
            if settings.volumeSizeBytes > 0 {
                Self.cleanupSplitVolumes(baseArchiveURL: archiveURL)
            }
            throw error
        }
    }

    // MARK: - Single Entry Extraction (Quick Look & Drag-Out via Warm Interactive Worker)

    public func extractEntry(
        from archiveURL: URL,
        entryPath: String,
        to destinationURL: URL,
        password: String? = nil
    ) async throws {
        if FormatDetector.detectReadableFormat(of: archiveURL) == .aar {
            try await AppleArchiveEngine().extractEntry(
                from: archiveURL,
                entryPath: entryPath,
                to: destinationURL
            )
            return
        }
        let safeRelPath = try Bento7zPathSafety.sanitizedRelativePath(entryPath)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_single_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let directExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safeRelPath, baseDirectory: tempDir)
        let flatName = (safeRelPath as NSString).lastPathComponent
        let flatExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: flatName, baseDirectory: tempDir)

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        if prefersBinaryServer {
            let tarCacheURL = cacheManager.tarCacheURL(for: archiveURL, isEncrypted: !(password ?? "").isEmpty)
            let client = Bento7zInteractiveWorkerPool.shared.client(
                binaryPath: runner.binaryPath,
                libraryPath: runner.libraryPath
            )
            let payload = Bento7zBinaryProtocol.encodeExtractRequest(
                archivePath: archiveURL.path,
                outputDir: tempDir.path,
                password: password,
                format: FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName,
                tarCachePath: tarCacheURL?.path,
                entries: [safeRelPath]
            )
            _ = try await client.sendRequest(type: .extract, payload: payload, hardKillOnCancel: false)
            if let tarCacheURL, fm.fileExists(atPath: tarCacheURL.path) {
                cacheManager.recordMaterializedTar(for: archiveURL, at: tarCacheURL)
            }
        } else {
            var params: [String: Any] = [
                "archive": archiveURL.path,
                "output": tempDir.path,
                "entries": [safeRelPath]
            ]
            if let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName {
                params["format"] = formatHint
            }
            if let password, !password.isEmpty {
                params["password"] = password
            }
            _ = try await runner.execute(command: "extract", params: params)
        }

        let extractedFile: URL
        if fm.fileExists(atPath: directExtracted.path) {
            extractedFile = directExtracted
        } else if fm.fileExists(atPath: flatExtracted.path) {
            extractedFile = flatExtracted
        } else {
            throw Bento7zError.fileNotFound(entryPath)
        }

        let destParent = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destParent.path) {
            try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: extractedFile, to: destinationURL)
    }

    // MARK: - Binary Server Implementations

    private func listArchiveBinary(
        in archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        let isEncrypted = !(password ?? "").isEmpty
        let tarCacheURL = cacheManager.tarCacheURL(for: archiveURL, isEncrypted: isEncrypted)
        let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName

        let client = Bento7zInteractiveWorkerPool.shared.client(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath
        )

        final class ListCollector: @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock(initialState: State())
            struct State {
                var entries: [ArchiveTreeBuilder.FlatEntry] = []
                var packedSize: Int64?
                var usedTarCache = false
            }

            func setMeta(_ meta: Bento7zBinaryProtocol.ListMetaPayload) {
                lock.withLock { state in
                    state.packedSize = meta.packedSize > 0 ? meta.packedSize : nil
                    state.usedTarCache = meta.usedTarCache
                    if meta.itemsCount > 0 {
                        state.entries.reserveCapacity(Int(min(meta.itemsCount, 2_000_000)))
                    }
                }
            }

            func append(_ chunk: [ArchiveTreeBuilder.FlatEntry]) {
                lock.withLock { $0.entries.append(contentsOf: chunk) }
            }

            func takeSnapshot() -> (entries: [ArchiveTreeBuilder.FlatEntry], packedSize: Int64?) {
                lock.withLock { state in
                    let items = state.entries
                    state.entries.removeAll(keepingCapacity: false)
                    return (items, state.packedSize)
                }
            }
        }

        let collector = ListCollector()
        let payload = Bento7zBinaryProtocol.encodeListRequest(
            archivePath: archiveURL.path,
            password: password,
            format: formatHint,
            tarCachePath: tarCacheURL?.path
        )

        let progressForwarder: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)?
        if let onProgress {
            let mapper = ProgressStageMapper(context: .list)
            progressForwarder = { @Sendable progress in
                onProgress(mapper.map(Self.archiveProgress(from: progress)))
            }
        } else {
            progressForwarder = nil
        }

        _ = try await client.sendRequest(
            type: .list,
            payload: payload,
            hardKillOnCancel: false,
            onProgress: progressForwarder,
            onListMeta: { meta in
                collector.setMeta(meta)
            },
            onListChunk: { chunk in
                collector.append(chunk)
            }
        )

        try Task.checkCancellation()

        if let tarCacheURL, FileManager.default.fileExists(atPath: tarCacheURL.path) {
            cacheManager.recordMaterializedTar(for: archiveURL, at: tarCacheURL)
        }

        let (flatEntries, archivePackedSize) = collector.takeSnapshot()
        let buildTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let tree = ArchiveTreeBuilder.build(from: flatEntries)
            return ArchiveListResult(entries: tree, archivePackedSize: archivePackedSize)
        }
        return try await withTaskCancellationHandler {
            try await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }
    }

    private func extractBinary(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        let isEncrypted = !(password ?? "").isEmpty
        let tarCacheURL = cacheManager.tarCacheURL(for: archiveURL, isEncrypted: isEncrypted)
        let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName
        let entryPaths = entries.map { Bento7zPathSafety.collectArchivePaths(from: $0) } ?? []

        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "extract"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeExtractRequest(
            archivePath: archiveURL.path,
            outputDir: destinationURL.path,
            password: password,
            format: formatHint,
            tarCachePath: tarCacheURL?.path,
            entries: entryPaths
        )

        let mapper = ProgressStageMapper(context: .extract)
        _ = try await worker.sendRequest(
            type: .extract,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: { progress in
                onProgress(mapper.map(Self.archiveProgress(from: progress)))
            }
        )

        if let tarCacheURL, FileManager.default.fileExists(atPath: tarCacheURL.path) {
            cacheManager.recordMaterializedTar(for: archiveURL, at: tarCacheURL)
        }
        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    private func compressBinary(
        from sourceURLs: [URL],
        to archiveURL: URL,
        formatName: String,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "compress"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let encryptionMethod = (settings.format == .zip && !(settings.password ?? "").isEmpty)
            ? settings.zipEncryptionMethod.bento7zValue
            : nil
        let payload = Bento7zBinaryProtocol.encodeCompressRequest(
            archivePath: archiveURL.path,
            format: formatName,
            level: levelString(from: settings.compressionLevel),
            password: settings.password,
            preservePaths: settings.preserveDirectoryStructure,
            paths: sourceURLs.map(\.path),
            exclude: settings.exclusionPatterns,
            volumeSizeBytes: settings.volumeSizeBytes,
            encryptionMethod: encryptionMethod
        )

        let mapper = ProgressStageMapper(context: .compress)
        _ = try await worker.sendRequest(
            type: .compress,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: { progress in
                onProgress(mapper.map(Self.archiveProgress(from: progress)))
            }
        )
    }

    // MARK: - JSONL Fallback (for mock CLI scripts in tests)

    private func listArchiveJSONL(
        in archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        var params: [String: Any] = ["archive": archiveURL.path]
        if let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName {
            params["format"] = formatHint
        }
        if let password, !password.isEmpty {
            params["password"] = password
        }

        let wrappedProgress: (@Sendable (ArchiveProgress) -> Void)?
        if let onProgress {
            let mapper = ProgressStageMapper(context: .list)
            wrappedProgress = { @Sendable progress in
                onProgress(mapper.map(progress))
            }
        } else {
            wrappedProgress = nil
        }
        let result = try await runner.execute(command: "list", params: params, onProgress: wrappedProgress)
        try Task.checkCancellation()

        struct UncheckedResultBox: @unchecked Sendable {
            let value: [String: Any]
        }
        let boxedResult = UncheckedResultBox(value: result)

        let decodeTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let items = boxedResult.value["items"] as? [[String: Any]] else {
                throw Bento7zError.invalidResponse(String(localized: "Missing items field in list response", bundle: .module))
            }

            let archivePackedSize = (boxedResult.value["packed_size"] as? NSNumber)?.int64Value
            var flatEntries: [ArchiveTreeBuilder.FlatEntry] = []
            flatEntries.reserveCapacity(items.count)

            for (index, item) in items.enumerated() {
                if (index & 0x3FF) == 0 { try Task.checkCancellation() }
                let path = item["path"] as? String ?? ""
                let name = item["name"] as? String ?? (path as NSString).lastPathComponent
                let isDir = item["is_dir"] as? Bool ?? false
                let size = (item["size"] as? NSNumber)?.int64Value ?? 0
                let packedSize = (item["packed_size"] as? NSNumber)?.int64Value
                let isEncrypted = item["encrypted"] as? Bool ?? false
                let modDate: Date? = if let ts = (item["modified_at"] as? NSNumber)?.doubleValue, ts > 0 {
                    Date(timeIntervalSince1970: ts)
                } else {
                    nil
                }

                flatEntries.append(ArchiveTreeBuilder.FlatEntry(
                    path: path,
                    name: name,
                    isDirectory: isDir,
                    size: size,
                    packedSize: packedSize,
                    modificationDate: modDate,
                    isEncrypted: isEncrypted
                ))
            }

            try Task.checkCancellation()
            let tree = ArchiveTreeBuilder.build(from: flatEntries)
            return ArchiveListResult(entries: tree, archivePackedSize: archivePackedSize)
        }

        return try await withTaskCancellationHandler {
            try await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    private func executeDirectCompressJSONL(
        from sourceURLs: [URL],
        to archiveURL: URL,
        formatName: String,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        var params: [String: Any] = [
            "archive": archiveURL.path,
            "paths": sourceURLs.map(\.path),
            "format": formatName,
            "level": levelString(from: settings.compressionLevel),
            "preserve_paths": settings.preserveDirectoryStructure
        ]
        if let password = settings.password, !password.isEmpty {
            params["password"] = password
            if settings.format == .zip {
                params["encryption_method"] = settings.zipEncryptionMethod.bento7zValue
            }
        }
        if settings.volumeSizeBytes > 0 {
            params["volume_size_bytes"] = settings.volumeSizeBytes
        }
        if !settings.exclusionPatterns.isEmpty {
            params["exclude"] = settings.exclusionPatterns
        }

        let mapper = ProgressStageMapper(context: .compress)
        _ = try await runner.execute(command: "compress", params: params) { progress in
            onProgress(mapper.map(progress))
        }
    }

    // MARK: - Helpers

    /// Maps per-stage raw progress (`0...1`) into a single continuous, monotonic overall fraction
    /// for multi-stage compound `.tar.gz`/`.tar.bz2`/`.tar.xz` operations while preserving real
    /// per-stage byte counts for telemetry.
    final class ProgressStageMapper: @unchecked Sendable {
        enum Context {
            case list
            case extract
            case compress
        }

        private struct State {
            var sawUnpackingOuter = false
            var maxFraction: Double = 0.0
        }

        private let context: Context
        private let lock = OSAllocatedUnfairLock(initialState: State())

        init(context: Context) {
            self.context = context
        }

        func map(_ progress: ArchiveProgress) -> ArchiveProgress {
            let raw = min(max(progress.fractionCompleted, 0.0), 1.0)
            let weighted: Double = lock.withLock { state in
                let candidate: Double
                switch (context, progress.stage) {
                case (.list, .unpackingOuter):
                    state.sawUnpackingOuter = true
                    candidate = raw * 0.85
                case (.list, .readingEntries):
                    candidate = state.sawUnpackingOuter ? (0.85 + raw * 0.15) : raw
                case (.extract, .unpackingOuter):
                    state.sawUnpackingOuter = true
                    candidate = raw * 0.65
                case (.extract, .extractingInner):
                    candidate = 0.65 + raw * 0.35
                case (.compress, .packingTar):
                    candidate = raw * 0.25
                case (.compress, .compressingOuter):
                    candidate = 0.25 + raw * 0.75
                default:
                    candidate = raw
                }
                let monotonic = max(state.maxFraction, min(max(candidate, 0.0), 1.0))
                state.maxFraction = monotonic
                return monotonic
            }

            return ArchiveProgress(
                fractionCompleted: weighted,
                currentFile: progress.currentFile,
                processedBytes: progress.processedBytes,
                totalBytes: progress.totalBytes,
                isFileEvent: progress.isFileEvent,
                fileCountDelta: progress.fileCountDelta,
                stage: progress.stage
            )
        }
    }

    static func archiveProgress(from payload: Bento7zBinaryProtocol.ProgressPayload) -> ArchiveProgress {
        let fraction: Double
        if payload.totalBytes > 0 {
            fraction = min(max(Double(payload.processedBytes) / Double(payload.totalBytes), 0.0), 1.0)
        } else {
            fraction = 0.0
        }
        return ArchiveProgress(
            fractionCompleted: fraction,
            currentFile: payload.currentFile.isEmpty ? nil : payload.currentFile,
            processedBytes: payload.processedBytes,
            totalBytes: payload.totalBytes > 0 ? payload.totalBytes : nil,
            isFileEvent: payload.filesDelta > 0,
            fileCountDelta: payload.filesDelta,
            stage: payload.stage
        )
    }

    private func levelString(from level: CompressionLevel) -> String {
        switch level {
        case .none: return "none"
        case .fast: return "fast"
        case .normal: return "normal"
        case .best: return "ultra"
        }
    }

    static func splitVolumeURLs(for baseArchiveURL: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for idx in 1...999 {
            let suffix = String(format: ".%03d", idx)
            let url = URL(fileURLWithPath: baseArchiveURL.path + suffix)
            guard fm.fileExists(atPath: url.path) else { break }
            urls.append(url)
        }
        return urls
    }

    static func cleanupSplitVolumes(baseArchiveURL: URL) {
        let fm = FileManager.default
        for idx in 1...999 {
            let suffix = String(format: ".%03d", idx)
            let path = baseArchiveURL.path + suffix
            guard fm.fileExists(atPath: path) else {
                if idx > 1 { break }
                continue
            }
            try? fm.removeItem(atPath: path)
        }
    }

    private static func isScriptExecutable(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 2), header.count == 2 else { return false }
        return header[0] == 0x23 && header[1] == 0x21 // "#!"
    }
}
