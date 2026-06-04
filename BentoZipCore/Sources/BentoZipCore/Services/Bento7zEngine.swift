import Foundation

// MARK: - Errors

public enum Bento7zError: LocalizedError {
    case binaryNotFound(String)
    case processError(String)
    case invalidResponse(String)
    case operationFailed(String, String)  // message, code
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "bento7z binary not found at: \(path)"
        case .processError(let detail):
            return "bento7z process error: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid bento7z response: \(detail)"
        case .operationFailed(let message, let code):
            return "bento7z error [\(code)]: \(message)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}

// MARK: - Bento7zEngine

/// Archive engine that communicates with the bento7z CLI via JSONL over stdin/stdout.
/// Each operation spawns a fresh subprocess.
public struct Bento7zEngine: ArchiveEngine {

    // MARK: - Configuration

    private let binaryPath: String
    private let libraryPath: String

    public init(
        binaryPath: String? = nil,
        libraryPath: String? = nil
    ) {
        self.binaryPath = binaryPath ?? Self.defaultBinaryPath()
        self.libraryPath = libraryPath ?? Self.defaultLibraryPath()
    }

    // MARK: - Path Discovery

    private static func defaultBinaryPath() -> String {
        // Production: bundled in app Resources
        if let bundled = Bundle.main.path(forResource: "bento7z", ofType: nil) {
            return bundled
        }
        // Development fallback
        let devPath = "/Users/alikia/Code/bento7z/build/bento7z"
        if FileManager.default.isExecutableFile(atPath: devPath) {
            return devPath
        }
        return devPath
    }

    private static func defaultLibraryPath() -> String {
        // Production: bundled next to binary or in app Resources
        if let bundled = Bundle.main.path(forResource: "7z", ofType: "so") {
            return bundled
        }
        // Also check next to the binary
        let devDir = "/Users/alikia/Code/bento7z/build"
        let libPath = devDir + "/7z.so"
        if FileManager.default.fileExists(atPath: libPath) {
            return libPath
        }
        return libPath
    }

    // MARK: - Compression Level Mapping

    private func levelString(from level: CompressionLevel) -> String {
        switch level {
        case .none:   return "none"
        case .fast:   return "fast"
        case .normal: return "normal"
        case .best:   return "ultra"
        }
    }

    // MARK: - Format String Mapping

    private func formatString(from format: ArchiveFormat) -> String {
        switch format {
        case .zip:     return "zip"
        case .sevenZip: return "7z"
        case .tar: return "tar"
        }
    }

    // MARK: - Core Execution

    /// Runs bento7z with a single JSONL request, returns parsed response data.
    /// Calls `progress` closure for each "progress" line encountered.
    private func execute(
        command: String,
        params: [String: Any],
        progress: ((Double) -> Void)? = nil
    ) async throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw Bento7zError.binaryNotFound(binaryPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)

        var env = ProcessInfo.processInfo.environment
        env["BENTO7Z_LIBRARY"] = libraryPath
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write request to stdin
        let requestId = UUID().uuidString
        var requestDict: [String: Any] = [
            "id": requestId,
            "command": command,
            "params": params
        ]
        if var p = requestDict["params"] as? [String: Any] {
            p = p.filter { _, value in
                if let str = value as? String, str.isEmpty {
                    return false
                }
                return true
            }
            requestDict["params"] = p
        }

        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        var requestLine = requestData
        requestLine.append(10) // newline
        try stdinPipe.fileHandleForWriting.write(contentsOf: requestLine)
        try stdinPipe.fileHandleForWriting.close()

        // Read stdout lines asynchronously using modern async sequence
        var resultData: [String: Any]?
        var errorMessage: String?
        var errorCode: String?

        for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String ?? ""
            switch type {
            case "result":
                resultData = json["data"] as? [String: Any]
            case "progress":
                if let data = json["data"] as? [String: Any] {
                    let processed = (data["processed_bytes"] as? NSNumber)?.doubleValue ?? 0
                    let total = (data["total_bytes"] as? NSNumber)?.doubleValue ?? 1
                    if total > 0 {
                        progress?(processed / total)
                    }
                }
            case "error":
                if let data = json["data"] as? [String: Any] {
                    errorMessage = data["message"] as? String ?? "Unknown error"
                    errorCode = data["code"] as? String ?? "UNKNOWN"
                }
            default:
                break
            }
        }

        process.waitUntilExit()

        if let errorMessage = errorMessage {
            throw Bento7zError.operationFailed(errorMessage, errorCode ?? "UNKNOWN")
        }

        guard let result = resultData else {
            throw Bento7zError.invalidResponse("No result in response")
        }

        return result
    }

    // MARK: - ArchiveEngine Protocol

    public func listEntries(in archiveURL: URL) async throws -> [FileEntry] {
        let result = try await execute(
            command: "list",
            params: ["archive": archiveURL.path]
        )

        guard let items = result["items"] as? [[String: Any]] else {
            throw Bento7zError.invalidResponse("Missing 'items' in list result")
        }

        var flatEntries: [ArchiveTreeBuilder.FlatEntry] = []
        for item in items {
            let path = item["path"] as? String ?? ""
            let name = item["name"] as? String ?? (path as NSString).lastPathComponent
            let isDir = item["is_dir"] as? Bool ?? false
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0

            flatEntries.append(ArchiveTreeBuilder.FlatEntry(
                path: path,
                name: name,
                isDirectory: isDir,
                size: size,
                modificationDate: nil
            ))
        }

        return ArchiveTreeBuilder.build(from: flatEntries)
    }

    public func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        _ = try await execute(
            command: "extract",
            params: [
                "archive": archiveURL.path,
                "output": destinationURL.path
            ],
            progress: progress
        )

        progress(1.0)
    }

    public func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping (Double) -> Void
    ) async throws {
        // Ensure parent directory exists
        let parentDir = archiveURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Remove existing archive if present
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }

        let paths = sourceURLs.map { $0.path }
        let format = formatString(from: settings.format)
        let level = levelString(from: settings.compressionLevel)

        _ = try await execute(
            command: "compress",
            params: [
                "archive": archiveURL.path,
                "paths": paths,
                "format": format,
                "level": level
            ],
            progress: progress
        )

        progress(1.0)
    }

    public func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws {
        let fm = FileManager.default
        let namesToRemove = Set(entries.map { $0.name })

        // If all entries are being removed, just delete the archive
        let allEntries = try await listEntries(in: archiveURL)
        let allNames = Set(allEntries.map { $0.name })
        if namesToRemove.isSuperset(of: allNames) {
            try fm.removeItem(at: archiveURL)
            return
        }

        // Extract-then-rebuild approach
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BentoZip_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Extract all entries
        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            progress: { _ in }
        )

        // Remove the unwanted files/dirs
        for name in namesToRemove {
            let itemURL = extractDir.appendingPathComponent(name)
            if fm.fileExists(atPath: itemURL.path) {
                try fm.removeItem(at: itemURL)
            }
        }

        // Re-compress
        let remaining = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard !remaining.isEmpty else {
            try fm.removeItem(at: archiveURL)
            return
        }

        let format = FormatDetector.detectFormat(of: archiveURL) ?? .zip
        let settings = CompressionSettings(format: format, archiveName: archiveURL.lastPathComponent)

        try await create(
            from: remaining,
            to: newArchiveURL,
            settings: settings,
            progress: { _ in }
        )

        // Atomic replace
        let backupURL = tempDir.appendingPathComponent("backup_\(archiveURL.lastPathComponent)")
        try fm.moveItem(at: archiveURL, to: backupURL)
        do {
            try fm.moveItem(at: newArchiveURL, to: archiveURL)
            try? fm.removeItem(at: backupURL)
        } catch {
            // Rollback
            try? fm.removeItem(at: archiveURL)
            try fm.moveItem(at: backupURL, to: archiveURL)
            throw error
        }
    }

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            progress(1.0)
            return
        }

        let fm = FileManager.default

        // Extract-then-rebuild approach
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BentoZip_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Extract all existing entries
        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            progress: { _ in }
        )

        // Copy new files into extract directory
        for sourceURL in sourceURLs {
            let destURL = extractDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        }

        // Re-compress
        let allContents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let format = FormatDetector.detectFormat(of: archiveURL) ?? .zip
        let settings = CompressionSettings(format: format, archiveName: archiveURL.lastPathComponent)

        try await create(
            from: allContents,
            to: newArchiveURL,
            settings: settings,
            progress: progress
        )

        // Atomic replace
        let backupURL = tempDir.appendingPathComponent("backup_\(archiveURL.lastPathComponent)")
        try fm.moveItem(at: archiveURL, to: backupURL)
        do {
            try fm.moveItem(at: newArchiveURL, to: archiveURL)
            try? fm.removeItem(at: backupURL)
        } catch {
            try? fm.removeItem(at: archiveURL)
            try fm.moveItem(at: backupURL, to: archiveURL)
            throw error
        }
    }

    // MARK: - Convenience: extract single entry (used by DragDropManager)

    public func extractEntry(
        from archiveURL: URL,
        entryPath: String,
        to destinationURL: URL
    ) async throws {
        let fm = FileManager.default

        // Extract entire archive to a temp directory, then pick the one file
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BentoZip_single_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: tempDir,
            progress: { _ in }
        )

        let extractedFile = tempDir.appendingPathComponent(entryPath)
        guard fm.fileExists(atPath: extractedFile.path) else {
            throw Bento7zError.fileNotFound(entryPath)
        }

        // Ensure parent of destination exists
        let destParent = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destParent.path) {
            try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: extractedFile, to: destinationURL)
    }
}
