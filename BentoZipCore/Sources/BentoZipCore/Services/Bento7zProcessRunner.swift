import Foundation
import os

/// Coordinates thread-safe process termination when an async Swift task is cancelled.
final class ProcessController: @unchecked Sendable {
    private struct State {
        var process: Process?
        var isCancelled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    var isCancelled: Bool { lock.withLock { $0.isCancelled } }

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
        if let process, process.isRunning { process.terminate() }
    }

    func detach() { lock.withLock { $0.process = nil } }
}

/// Manages `bento7z` binary/library discovery and JSONL subprocess execution.
struct Bento7zProcessRunner: Sendable {
    private static let logger = Logger(subsystem: "com.bentozip.core", category: "Bento7zEngine")

    let binaryPath: String
    let libraryPath: String

    init(binaryPath: String? = nil, libraryPath: String? = nil) {
        let resolvedBinary = binaryPath ?? Self.defaultBinaryPath()
        self.binaryPath = resolvedBinary
        self.libraryPath = libraryPath ?? Self.defaultLibraryPath(relativeTo: resolvedBinary)
    }

    // MARK: - Path Discovery

    private static func bundledCandidates(resource: String, ext: String? = nil) -> [String] {
        let fileName = ext.map { "\(resource).\($0)" } ?? resource
        return [
            Bundle.main.url(forResource: resource, withExtension: ext)?.path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(fileName)").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(fileName).path,
            Bundle.main.resourceURL?.appendingPathComponent(fileName).path
        ].compactMap { $0 }
    }

    static func defaultBinaryPath() -> String {
        let fm = FileManager.default
        if let found = bundledCandidates(resource: "bento7z").first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        #if DEBUG
        return "/Users/alikia/Code/bento7z/build/bento7z"
        #else
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bento7z").path
        #endif
    }

    static func defaultLibraryPath(relativeTo binaryPath: String) -> String {
        let fm = FileManager.default
        let binaryDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().appendingPathComponent("7z.so").path
        let candidates = bundledCandidates(resource: "7z", ext: "so") + [binaryDir]
        if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            return found
        }
        #if DEBUG
        return "/Users/alikia/Code/bento7z/build/7z.so"
        #else
        return binaryDir
        #endif
    }

    // MARK: - Execution

    func execute(
        command: String,
        params: [String: Any],
        onProgress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw Bento7zError.binaryNotFound(binaryPath)
        }

        let cleanedParams = params.filter { _, value in
            if let str = value as? String { return !str.isEmpty }
            if let array = value as? [Any] { return !array.isEmpty }
            return true
        }
        let requestData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "command": command,
            "params": cleanedParams
        ] as [String: Any])

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

    private struct StreamState {
        var resultData: [String: Any]?
        var errorMessage: String?
        var errorCode: String?
        var lastFraction: Double = 0.0
        var lastCurrentFile: String?
        var lastProcessedBytes: Int64?
        var lastTotalBytes: Int64?
        var malformedLines: [String] = []
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

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
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
            let pending = exitLock.withLock { state -> CheckedContinuation<Int32, Never>? in
                state.status = status
                defer { state.continuation = nil }
                return state.continuation
            }
            pending?.resume(returning: status)
        }

        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            else { stderrBuffer.withLock { if $0.count < 65_536 { $0.append(chunk) } } }
        }

        struct StdoutState: @unchecked Sendable {
            var buffer = Data()
            var scanOffset = 0
            var stream = StreamState()
            var isFinished = false
            var continuation: CheckedContinuation<Void, Never>?
        }
        let stdoutLock = OSAllocatedUnfairLock(initialState: StdoutState())
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let pending = stdoutLock.withLock { state -> CheckedContinuation<Void, Never>? in
                    if !state.buffer.isEmpty,
                       !controller.isCancelled,
                       let trailing = String(data: state.buffer, encoding: .utf8) {
                        Self.handleOutputLine(trailing, state: &state.stream, onProgress: onProgress)
                    }
                    state.buffer.removeAll(keepingCapacity: false)
                    state.isFinished = true
                    defer { state.continuation = nil }
                    return state.continuation
                }
                pending?.resume()
                return
            }

            stdoutLock.withLock { state in
                guard !controller.isCancelled else { return }
                state.buffer.append(chunk)
                let newline = UInt8(ascii: "\n")
                var lineStart = state.buffer.startIndex
                var searchIndex = state.buffer.index(lineStart, offsetBy: state.scanOffset, limitedBy: state.buffer.endIndex) ?? state.buffer.endIndex

                while searchIndex < state.buffer.endIndex {
                    if state.buffer[searchIndex] == newline {
                        let lineData = state.buffer[lineStart..<searchIndex]
                        if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                            Self.handleOutputLine(line, state: &state.stream, onProgress: onProgress)
                        }
                        lineStart = state.buffer.index(after: searchIndex)
                        searchIndex = lineStart
                    } else {
                        searchIndex = state.buffer.index(after: searchIndex)
                    }
                }

                if lineStart > state.buffer.startIndex {
                    state.buffer.removeSubrange(state.buffer.startIndex..<lineStart)
                }
                state.scanOffset = state.buffer.count
            }
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            controller.detach()
        }

        guard controller.attach(process) else { throw CancellationError() }
        try process.run()

        var requestLine = requestData
        requestLine.append(10)
        try stdinPipe.fileHandleForWriting.write(contentsOf: requestLine)
        try stdinPipe.fileHandleForWriting.close()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFinished = stdoutLock.withLock { state -> Bool in
                if state.isFinished { return true }
                state.continuation = continuation
                return false
            }
            if alreadyFinished { continuation.resume() }
        }

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            let alreadyExited = exitLock.withLock { exitState -> Int32? in
                if let status = exitState.status { return status }
                exitState.continuation = continuation
                return nil
            }
            if let status = alreadyExited { continuation.resume(returning: status) }
        }

        let state = stdoutLock.withLock { $0.stream }

        if Task.isCancelled || controller.isCancelled { throw CancellationError() }
        if let errorMessage = state.errorMessage {
            throw Bento7zError.mapError(code: state.errorCode ?? "UNKNOWN", message: errorMessage)
        }
        if let resultData = state.resultData { return resultData }

        let stderrText = stderrBuffer.withLock {
            String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let malformedSummary = state.malformedLines.joined(separator: " | ")
        if exitStatus != 0 {
            let diagnostic = !stderrText.isEmpty ? stderrText : malformedSummary
            let detail = diagnostic.isEmpty
                ? String(localized: "Exit code \(Int64(exitStatus))", bundle: .module)
                : String(localized: "Exit code \(Int64(exitStatus)): \(diagnostic)", bundle: .module)
            throw Bento7zError.processError(detail)
        }
        if !malformedSummary.isEmpty {
            throw Bento7zError.invalidResponse(String(localized: "Malformed output: \(malformedSummary)", bundle: .module))
        }
        throw Bento7zError.invalidResponse(String(localized: "Missing result field in response", bundle: .module))
    }

    private static func handleOutputLine(
        _ line: String,
        state: inout StreamState,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let lineData = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            Self.logger.warning("Ignoring malformed JSONL output from bento7z: \(trimmed, privacy: .public)")
            if state.malformedLines.count < 5 { state.malformedLines.append(trimmed) }
            return
        }

        switch json["type"] as? String ?? "" {
        case "result":
            state.resultData = json["data"] as? [String: Any]
        case "progress":
            guard let data = json["data"] as? [String: Any] else { return }
            let processed = (data["processed_bytes"] as? NSNumber)?.int64Value
            let total = (data["total_bytes"] as? NSNumber)?.int64Value
            if let processed { state.lastProcessedBytes = processed }
            if let total, total > 0 { state.lastTotalBytes = total }
            if let currentFile = data["current_file"] as? String, !currentFile.isEmpty {
                state.lastCurrentFile = currentFile
            }
            if let processed = state.lastProcessedBytes, let total = state.lastTotalBytes, total > 0 {
                state.lastFraction = min(max(Double(processed) / Double(total), 0.0), 1.0)
            }
            onProgress?(ArchiveProgress(
                fractionCompleted: state.lastFraction,
                currentFile: state.lastCurrentFile,
                processedBytes: state.lastProcessedBytes,
                totalBytes: state.lastTotalBytes,
                isFileEvent: false
            ))
        case "file":
            let data = json["data"] as? [String: Any]
            if let filePath = (data?["path"] as? String) ?? (json["path"] as? String), !filePath.isEmpty {
                state.lastCurrentFile = filePath
                onProgress?(ArchiveProgress(
                    fractionCompleted: state.lastFraction,
                    currentFile: filePath,
                    processedBytes: state.lastProcessedBytes,
                    totalBytes: state.lastTotalBytes,
                    isFileEvent: true
                ))
            }
        case "error":
            if let data = json["data"] as? [String: Any] {
                state.errorMessage = data["message"] as? String ?? "Unknown error"
                state.errorCode = data["code"] as? String ?? "UNKNOWN"
            }
        default:
            break
        }
    }
}
