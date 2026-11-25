import Foundation

/// Archive engine communicating with the `bento7z` CLI via JSONL over stdin/stdout.
/// Each operation spawns an isolated subprocess off the main actor with cancellation support.
public struct Bento7zEngine: ArchiveEngine, Sendable {

    let runner: Bento7zProcessRunner

    public init(
        binaryPath: String? = nil,
        libraryPath: String? = nil
    ) {
        self.runner = Bento7zProcessRunner(binaryPath: binaryPath, libraryPath: libraryPath)
    }

    // MARK: - ArchiveEngine Protocol

    public func listEntries(in archiveURL: URL, password: String? = nil) async throws -> [FileEntry] {
        try await listArchive(in: archiveURL, password: password).entries
    }

    public func listArchive(in archiveURL: URL, password: String? = nil) async throws -> ArchiveListResult {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        var params: [String: Any] = ["archive": archiveURL.path]
        if let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName {
            params["format"] = formatHint
        }
        if let password, !password.isEmpty {
            params["password"] = password
        }

        let result = try await runner.execute(command: "list", params: params)
        try Task.checkCancellation()

        // Decode large JSON entry arrays and build the sorted hierarchy off the main actor.
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
                let modDate: Date?
                if let timestamp = (item["modified_at"] as? NSNumber)?.doubleValue, timestamp > 0 {
                    modDate = Date(timeIntervalSince1970: timestamp)
                } else {
                    modDate = nil
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

        _ = try await runner.execute(
            command: "extract",
            params: params,
            onProgress: onProgress
        )

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

        do {
            try await executeDirectCompress(
                from: sourceURLs,
                to: archiveURL,
                formatName: settings.format.bento7zFormatName,
                settings: settings,
                onProgress: onProgress
            )
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
        } catch {
            try? fm.removeItem(at: archiveURL)
            throw error
        }
    }

    // MARK: - Single Entry Extraction (Drag & Drop)

    public func extractEntry(
        from archiveURL: URL,
        entryPath: String,
        to destinationURL: URL,
        password: String? = nil
    ) async throws {
        let safeRelPath = try Bento7zPathSafety.sanitizedRelativePath(entryPath)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_single_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let directExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safeRelPath, baseDirectory: tempDir)
        let flatName = (safeRelPath as NSString).lastPathComponent
        let flatExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: flatName, baseDirectory: tempDir)

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

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

    // MARK: - Parameter Mapping

    private func levelString(from level: CompressionLevel) -> String {
        switch level {
        case .none: return "none"
        case .fast: return "fast"
        case .normal: return "normal"
        case .best: return "ultra"
        }
    }

    private func executeDirectCompress(
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
        }
        if !settings.exclusionPatterns.isEmpty {
            params["exclude"] = settings.exclusionPatterns
        }

        _ = try await runner.execute(
            command: "compress",
            params: params,
            onProgress: onProgress
        )
    }
}
