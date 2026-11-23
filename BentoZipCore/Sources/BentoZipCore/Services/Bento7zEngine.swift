import Foundation
import os

// MARK: - Errors

public enum Bento7zError: LocalizedError, Equatable {
    case binaryNotFound(String)
    case processError(String)
    case invalidResponse(String)
    case operationFailed(String, String)
    case fileNotFound(String)
    case passwordRequired
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "未找到压缩引擎组件: \(path)"
        case .processError(let detail):
            return "引擎进程异常: \(detail)"
        case .invalidResponse(let detail):
            return "无效的引擎响应: \(detail)"
        case .operationFailed(let message, let code):
            return "操作失败 [\(code)]: \(message)"
        case .fileNotFound(let path):
            return "未找到文件: \(path)"
        case .passwordRequired:
            return "此压缩包受密码保护，请输入密码"
        case .wrongPassword:
            return "密码错误，请重新输入"
        }
    }

    static func mapError(code: String, message: String) -> Bento7zError {
        if code == "PASSWORD_REQUIRED" {
            return .passwordRequired
        }
        if code == "WRONG_PASSWORD" {
            return .wrongPassword
        }

        let lower = message.lowercased()
        if code == "BIT7Z_ERROR" || lower.contains("password") || lower.contains("encrypted") {
            if lower.contains("wrong password")
                || lower.contains("incorrect password")
                || lower.contains("invalid password")
                || lower.contains("bad password") {
                return .wrongPassword
            }
            if lower.contains("password") || lower.contains("encrypted") {
                return .passwordRequired
            }
        }

        return .operationFailed(message, code)
    }
}

// MARK: - Process Cancellation Controller

private final class ProcessController: @unchecked Sendable {
    private struct State {
        var process: Process?
        var isCancelled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool {
        lock.withLock { $0.isCancelled }
    }

    func attach(_ process: Process) -> Bool {
        lock.withLock { state in
            guard !state.isCancelled else { return false }
            state.process = process
            return true
        }
    }

    func cancel() {
        let process = lock.withLock { state -> Process? in
            state.isCancelled = true
            return state.process
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func detach() {
        lock.withLock { state in
            state.process = nil
        }
    }
}

// MARK: - Bento7zEngine

/// Archive engine communicating with the `bento7z` CLI via JSONL over stdin/stdout.
/// Each operation spawns an isolated subprocess off the main actor with cancellation support.
public struct Bento7zEngine: ArchiveEngine, Sendable {

    private static let logger = Logger(subsystem: "com.bentozip.core", category: "Bento7zEngine")

    private let binaryPath: String
    private let libraryPath: String

    public init(
        binaryPath: String? = nil,
        libraryPath: String? = nil
    ) {
        let resolvedBinary = binaryPath ?? Self.defaultBinaryPath()
        self.binaryPath = resolvedBinary
        self.libraryPath = libraryPath ?? Self.defaultLibraryPath(relativeTo: resolvedBinary)
    }

    // MARK: - Path Discovery

    private static func defaultBinaryPath() -> String {
        let fm = FileManager.default
        let candidates: [String?] = [
            Bundle.main.url(forResource: "bento7z", withExtension: nil)?.path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bento7z").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bento7z").path,
            Bundle.main.resourceURL?.appendingPathComponent("bento7z").path
        ]
        for case let candidate? in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        #if DEBUG
        return "/Users/alikia/Code/bento7z/build/bento7z"
        #else
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bento7z").path
        #endif
    }

    private static func defaultLibraryPath(relativeTo binaryPath: String) -> String {
        let fm = FileManager.default
        let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().appendingPathComponent("7z.so").path
        let candidates: [String?] = [
            Bundle.main.url(forResource: "7z", withExtension: "so")?.path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7z.so").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("7z.so").path,
            Bundle.main.resourceURL?.appendingPathComponent("7z.so").path,
            binaryDir
        ]
        for case let candidate? in candidates where fm.fileExists(atPath: candidate) {
            return candidate
        }
        #if DEBUG
        return "/Users/alikia/Code/bento7z/build/7z.so"
        #else
        return binaryDir
        #endif
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

    private func filteredParams(_ params: [String: Any]) -> [String: Any] {
        params.filter { _, value in
            if let str = value as? String {
                return !str.isEmpty
            }
            if let array = value as? [Any] {
                return !array.isEmpty
            }
            return true
        }
    }

    // MARK: - Core Execution

    private func execute(
        command: String,
        params: [String: Any],
        onProgress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw Bento7zError.binaryNotFound(binaryPath)
        }

        let cleanedParams = filteredParams(params)
        let requestDict: [String: Any] = [
            "id": UUID().uuidString,
            "command": command,
            "params": cleanedParams
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestDict)
        let binaryPath = self.binaryPath
        let libraryPath = self.libraryPath
        let controller = ProcessController()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try await Self.runProcess(
                    binaryPath: binaryPath,
                    libraryPath: libraryPath,
                    requestData: requestData,
                    controller: controller,
                    onProgress: onProgress
                )
            }.value
        } onCancel: {
            controller.cancel()
        }
    }

    private static func runProcess(
        binaryPath: String,
        libraryPath: String,
        requestData: Data,
        controller: ProcessController,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> [String: Any] {
        try Task.checkCancellation()

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

        struct ExitState: Sendable {
            var status: Int32?
            var continuation: CheckedContinuation<Int32, Never>?
        }
        let exitLock = OSAllocatedUnfairLock(initialState: ExitState())

        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            let continuation = exitLock.withLock { state -> CheckedContinuation<Int32, Never>? in
                state.status = status
                let pending = state.continuation
                state.continuation = nil
                return pending
            }
            continuation?.resume(returning: status)
        }

        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.withLock { data in
                    if data.count < 65_536 {
                        data.append(chunk)
                    }
                }
            }
        }

        defer {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            controller.detach()
        }

        guard controller.attach(process) else {
            throw CancellationError()
        }

        try process.run()

        var requestLine = requestData
        requestLine.append(10)
        try stdinPipe.fileHandleForWriting.write(contentsOf: requestLine)
        try stdinPipe.fileHandleForWriting.close()

        var resultData: [String: Any]?
        var errorMessage: String?
        var errorCode: String?
        var lastFraction: Double = 0.0
        var lastCurrentFile: String?
        var malformedLines: [String] = []

        for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
            if Task.isCancelled || controller.isCancelled { break }
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            guard let lineData = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                Self.logger.warning("Ignoring malformed JSONL output from bento7z: \(trimmedLine, privacy: .public)")
                if malformedLines.count < 5 {
                    malformedLines.append(trimmedLine)
                }
                continue
            }

            let type = json["type"] as? String ?? ""
            switch type {
            case "result":
                resultData = json["data"] as? [String: Any]

            case "progress":
                if let data = json["data"] as? [String: Any] {
                    let processed = (data["processed_bytes"] as? NSNumber)?.int64Value
                    let total = (data["total_bytes"] as? NSNumber)?.int64Value
                    if let currentFile = data["current_file"] as? String, !currentFile.isEmpty {
                        lastCurrentFile = currentFile
                    }
                    let fraction: Double
                    if let processed, let total, total > 0 {
                        fraction = min(max(Double(processed) / Double(total), 0.0), 1.0)
                    } else {
                        fraction = lastFraction
                    }
                    lastFraction = fraction
                    onProgress?(ArchiveProgress(
                        fractionCompleted: fraction,
                        currentFile: lastCurrentFile,
                        processedBytes: processed,
                        totalBytes: total
                    ))
                }

            case "file":
                let data = json["data"] as? [String: Any]
                if let filePath = (data?["path"] as? String) ?? (json["path"] as? String), !filePath.isEmpty {
                    lastCurrentFile = filePath
                    onProgress?(ArchiveProgress(
                        fractionCompleted: lastFraction,
                        currentFile: filePath
                    ))
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

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            let alreadyExited = exitLock.withLock { state -> Int32? in
                if let status = state.status {
                    return status
                }
                state.continuation = continuation
                return nil
            }
            if let status = alreadyExited {
                continuation.resume(returning: status)
            }
        }

        if Task.isCancelled || controller.isCancelled {
            throw CancellationError()
        }

        if let errorMessage {
            throw Bento7zError.mapError(code: errorCode ?? "UNKNOWN", message: errorMessage)
        }

        if let resultData {
            return resultData
        }

        let stderrText = stderrBuffer.withLock { data in
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let malformedSummary = malformedLines.joined(separator: " | ")
        if exitStatus != 0 {
            let diagnostic = !stderrText.isEmpty ? stderrText : malformedSummary
            let detail = diagnostic.isEmpty ? "退出码 \(exitStatus)" : "退出码 \(exitStatus): \(diagnostic)"
            throw Bento7zError.processError(detail)
        }

        if !malformedSummary.isEmpty {
            throw Bento7zError.invalidResponse("响应格式异常: \(malformedSummary)")
        }
        throw Bento7zError.invalidResponse("响应中缺少 result 字段")
    }

    // MARK: - ArchiveEngine Protocol

    public func listEntries(in archiveURL: URL, password: String? = nil) async throws -> [FileEntry] {
        try await listArchive(in: archiveURL, password: password).entries
    }

    public func listArchive(in archiveURL: URL, password: String? = nil) async throws -> ArchiveListResult {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        var params: [String: Any] = [
            "archive": archiveURL.path
        ]
        if let formatHint = FormatDetector.detectReadableFormat(of: archiveURL)?.bento7zFormatName {
            params["format"] = formatHint
        }
        if let password, !password.isEmpty {
            params["password"] = password
        }

        let result = try await execute(command: "list", params: params)

        guard let items = result["items"] as? [[String: Any]] else {
            throw Bento7zError.invalidResponse("list 响应缺少 items 字段")
        }

        let archivePackedSize = (result["packed_size"] as? NSNumber)?.int64Value

        var flatEntries: [ArchiveTreeBuilder.FlatEntry] = []
        flatEntries.reserveCapacity(items.count)

        for item in items {
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

        let tree = ArchiveTreeBuilder.build(from: flatEntries)
        return ArchiveListResult(entries: tree, archivePackedSize: archivePackedSize)
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
            let entryPaths = collectArchivePaths(from: entries)
            if !entryPaths.isEmpty {
                params["entries"] = entryPaths
            }
        }

        _ = try await execute(
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

    public func removeEntries(
        from archiveURL: URL,
        entries: [FileEntry],
        password: String? = nil
    ) async throws {
        guard !entries.isEmpty else { return }
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed("不支持修改只读压缩包格式", "UNSUPPORTED_FORMAT")
        }

        let fm = FileManager.default
        let allEntries = try await listEntries(in: archiveURL, password: password)
        let removalPaths = Set(entries.map { archiveRelativePath(for: $0) })
        let allPaths = Set(allEntries.map { archiveRelativePath(for: $0) })

        if removalPaths.isSuperset(of: allPaths) && !allPaths.isEmpty {
            try fm.removeItem(at: archiveURL)
            return
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_remove_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Validate all target removal paths up front before touching the filesystem.
        var validatedTargets: [(primary: URL, fallback: URL?)] = []
        validatedTargets.reserveCapacity(entries.count)
        for entry in entries {
            let relPath = archiveRelativePath(for: entry)
            let directTarget = try Self.verifiedDescendantURL(relativePath: relPath, baseDirectory: extractDir)
            let fallbackTarget: URL?
            if !entry.name.isEmpty,
               !entry.name.contains("/"),
               !entry.name.contains("\\"),
               entry.name != ".",
               entry.name != ".." {
                fallbackTarget = try Self.verifiedDescendantURL(relativePath: entry.name, baseDirectory: extractDir)
            } else {
                fallbackTarget = nil
            }
            validatedTargets.append((directTarget, fallbackTarget))
        }

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: password,
            onProgress: { _ in }
        )

        for target in validatedTargets {
            if fm.fileExists(atPath: target.primary.path) {
                try fm.removeItem(at: target.primary)
                continue
            }
            if let fallback = target.fallback, fm.fileExists(atPath: fallback.path) {
                try fm.removeItem(at: fallback)
            }
        }

        let remaining = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard !remaining.isEmpty else {
            try fm.removeItem(at: archiveURL)
            return
        }

        let settings = CompressionSettings(
            format: format,
            archiveName: archiveURL.lastPathComponent,
            exclusionPatterns: [],
            password: password
        )

        try await create(
            from: remaining,
            to: newArchiveURL,
            settings: settings,
            onProgress: { _ in }
        )

        try replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
    }

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        password: String? = nil,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed("不支持修改只读压缩包格式", "UNSUPPORTED_FORMAT")
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_add_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: password,
            onProgress: { update in
                onProgress(ArchiveProgress(
                    fractionCompleted: update.fractionCompleted * 0.4,
                    currentFile: update.currentFile
                ))
            }
        )

        for sourceURL in sourceURLs {
            try Task.checkCancellation()
            let destURL = extractDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        }

        let allContents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let settings = CompressionSettings(
            format: format,
            archiveName: archiveURL.lastPathComponent,
            exclusionPatterns: [],
            password: password
        )

        try await create(
            from: allContents,
            to: newArchiveURL,
            settings: settings,
            onProgress: { update in
                onProgress(ArchiveProgress(
                    fractionCompleted: 0.4 + update.fractionCompleted * 0.6,
                    currentFile: update.currentFile
                ))
            }
        )

        try replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    // MARK: - Single Entry Extraction (Drag & Drop)

    public func extractEntry(
        from archiveURL: URL,
        entryPath: String,
        to destinationURL: URL,
        password: String? = nil
    ) async throws {
        let safeRelPath = try Self.sanitizedRelativePath(entryPath)

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_single_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let directExtracted = try Self.verifiedDescendantURL(relativePath: safeRelPath, baseDirectory: tempDir)
        let flatName = (safeRelPath as NSString).lastPathComponent
        let flatExtracted = try Self.verifiedDescendantURL(relativePath: flatName, baseDirectory: tempDir)

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

        _ = try await execute(command: "extract", params: params)

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

    // MARK: - Private Helpers

    private static func sanitizedRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0") else {
            throw Bento7zError.operationFailed("检测到非法归档路径: \(rawPath)", "INVALID_PATH")
        }
        if normalized.count >= 2,
           let first = normalized.first, first.isLetter,
           normalized[normalized.index(after: normalized.startIndex)] == ":" {
            throw Bento7zError.operationFailed("检测到非法归档路径: \(rawPath)", "INVALID_PATH")
        }
        var components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("..") else {
            throw Bento7zError.operationFailed("检测到非法路径穿越: \(rawPath)", "INVALID_PATH")
        }
        while components.first == "." {
            components.removeFirst()
        }
        guard !components.isEmpty else {
            throw Bento7zError.operationFailed("检测到非法归档路径: \(rawPath)", "INVALID_PATH")
        }
        return components.joined(separator: "/")
    }

    private static func verifiedDescendantURL(relativePath: String, baseDirectory: URL) throws -> URL {
        let safeRel = try sanitizedRelativePath(relativePath)
        let basePath = baseDirectory.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetURL = baseDirectory.appendingPathComponent(safeRel)
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(basePrefix) else {
            throw Bento7zError.operationFailed("目标路径越界: \(relativePath)", "INVALID_PATH")
        }
        return targetURL
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
            "paths": sourceURLs.map { $0.path },
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

        _ = try await execute(
            command: "compress",
            params: params,
            onProgress: onProgress
        )
    }

    private func replaceArchiveAtomically(at archiveURL: URL, with newArchiveURL: URL, tempDir: URL) throws {
        let fm = FileManager.default
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

    private func archiveRelativePath(for entry: FileEntry) -> String {
        if let rel = entry.archiveRelativePath, !rel.isEmpty {
            return rel
        }
        let fullPath = entry.url.path
        if fullPath.hasPrefix("/archive-root/") {
            return String(fullPath.dropFirst("/archive-root/".count))
        }
        return fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
    }

    private func collectArchivePaths(from entries: [FileEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func appendUnique(_ path: String) {
            if !path.isEmpty && seen.insert(path).inserted {
                result.append(path)
            }
        }

        func walk(_ entry: FileEntry) {
            appendUnique(archiveRelativePath(for: entry))
            if let children = entry.children {
                for child in children {
                    walk(child)
                }
            }
        }

        for entry in entries {
            walk(entry)
        }
        return result
    }
}
