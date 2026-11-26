import Darwin
import Foundation
import os

/// Full-async multiplexed Unix Domain Socket client for `bento7z --server <socket-path>`.
/// Supports concurrent in-flight requests, streaming binary list chunks, coalesced progress frames,
/// per-request cooperative cancellation, and automatic recovery if a worker crashes.
final class Bento7zBinaryClient: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.bentozip.core", category: "Bento7zBinaryClient")

    struct CallHandlers {
        let onProgress: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)?
        let onListMeta: (@Sendable (Bento7zBinaryProtocol.ListMetaPayload) -> Void)?
        let onListChunk: (@Sendable ([ArchiveTreeBuilder.FlatEntry]) -> Void)?
        let onComplete: @Sendable (Result<Bento7zBinaryProtocol.ResultPayload, Error>) -> Void
    }

    private final class RequestSlot: @unchecked Sendable {
        var isRegistered = false
        var isCancelled = false
    }

    private struct ConnectionState {
        var process: Process?
        var socketFD: Int32 = -1
        var readSource: DispatchSourceRead?
        var socketPath: String?
        var nextRequestID: UInt64 = 1
        var pending: [UInt64: CallHandlers] = [:]
        var readBuffer = Data()
        var isClosed = false
    }

    let binaryPath: String
    let libraryPath: String
    private let lock = OSAllocatedUnfairLock(initialState: ConnectionState())
    private let connectLock = NSLock()
    private let ioQueue: DispatchQueue
    private let writeQueue: DispatchQueue

    init(binaryPath: String, libraryPath: String, label: String = "interactive") {
        self.binaryPath = binaryPath
        self.libraryPath = libraryPath
        self.ioQueue = DispatchQueue(label: "com.bentozip.bento7z.io.\(label)", qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: "com.bentozip.bento7z.write.\(label)", qos: .userInitiated)
    }

    deinit {
        shutdown(terminateProcess: true)
    }

    // MARK: - Public Async Request API

    func sendRequest(
        type: Bento7zBinaryProtocol.RequestType,
        payload: Data,
        hardKillOnCancel: Bool = false,
        onProgress: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)? = nil,
        onListMeta: (@Sendable (Bento7zBinaryProtocol.ListMetaPayload) -> Void)? = nil,
        onListChunk: (@Sendable ([ArchiveTreeBuilder.FlatEntry]) -> Void)? = nil
    ) async throws -> Bento7zBinaryProtocol.ResultPayload {
        try Task.checkCancellation()
        try await ensureConnected()

        let requestID = lock.withLock { state -> UInt64 in
            let id = state.nextRequestID
            state.nextRequestID &+= 1
            return id
        }

        let frame = Bento7zBinaryProtocol.encodeFrame(type: type, requestID: requestID, payload: payload)
        let slot = RequestSlot()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handlers = CallHandlers(
                    onProgress: onProgress,
                    onListMeta: onListMeta,
                    onListChunk: onListChunk,
                    onComplete: { result in
                        continuation.resume(with: result)
                    }
                )

                let preflightError: Error? = lock.withLock { state in
                    if Task.isCancelled || slot.isCancelled {
                        slot.isCancelled = true
                        return CancellationError()
                    }
                    guard !state.isClosed, state.socketFD >= 0 else {
                        return Bento7zError.processError("Binary worker connection closed")
                    }
                    slot.isRegistered = true
                    state.pending[requestID] = handlers
                    enqueueWrite(frame, on: state.socketFD, requestID: requestID)
                    return nil
                }

                if let preflightError {
                    continuation.resume(throwing: preflightError)
                }
            }
        } onCancel: { [weak self] in
            self?.cancelRequest(requestID: requestID, slot: slot, hardKillFallback: hardKillOnCancel)
        }
    }

    func shutdown(terminateProcess: Bool = true) {
        let teardown: (Process?, Int32, DispatchSourceRead?, String?, [CallHandlers]) = lock.withLock { state in
            let proc = state.process
            let fd = state.socketFD
            let source = state.readSource
            let path = state.socketPath
            let pendingHandlers = Array(state.pending.values)

            state.process = nil
            state.socketFD = -1
            state.readSource = nil
            state.socketPath = nil
            state.pending.removeAll()
            state.readBuffer.removeAll(keepingCapacity: false)
            state.isClosed = true

            return (proc, fd, source, path, pendingHandlers)
        }

        if let readSource = teardown.2 {
            readSource.cancel()
        } else if teardown.1 >= 0 {
            Darwin.close(teardown.1)
        }
        if terminateProcess, let proc = teardown.0, proc.isRunning {
            proc.terminate()
        }
        if let path = teardown.3 {
            try? FileManager.default.removeItem(atPath: path)
        }
        for handler in teardown.4 {
            handler.onComplete(.failure(CancellationError()))
        }
    }

    // MARK: - Connection Lifecycle

    private func ensureConnected() async throws {
        let alreadyReady = lock.withLock { state -> Bool in
            guard !state.isClosed, state.socketFD >= 0, let proc = state.process, proc.isRunning else {
                return false
            }
            return true
        }
        if alreadyReady { return }

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw Bento7zError.binaryNotFound(binaryPath)
        }

        // Launch & connect off the cooperative thread pool.
        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw CancellationError() }
            try self.connectOrRestartSync()
        }.value
    }

    private func connectOrRestartSync() throws {
        connectLock.lock()
        defer { connectLock.unlock() }

        let alreadyConnected = lock.withLock { state -> Bool in
            state.socketFD >= 0 && (state.process?.isRunning == true) && !state.isClosed
        }
        if alreadyConnected { return }

        resetFailedConnection()

        let socketDir = FileManager.default.temporaryDirectory
        let shortID = UUID().uuidString.prefix(12)
        let socketPath = socketDir.appendingPathComponent("bz_\(shortID).sock").path
        try? FileManager.default.removeItem(atPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--server", socketPath]
        var env = ProcessInfo.processInfo.environment
        env["BENTO7Z_LIBRARY"] = libraryPath
        process.environment = env
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        process.terminationHandler = { [weak self] terminated in
            self?.handleDisconnect(forProcess: terminated, reason: "Worker process exited unexpectedly")
        }

        try process.run()

        // Connect with short backoff (typically ready in < 10 ms).
        let fd = try connectWithRetry(socketPath: socketPath, process: process)

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            self?.drainReadableSocket(fd: fd)
        }
        readSource.setCancelHandler {
            Darwin.close(fd)
        }

        let installed = lock.withLock { state -> Bool in
            if state.isClosed {
                return false
            }
            state.process = process
            state.socketFD = fd
            state.readSource = readSource
            state.socketPath = socketPath
            state.readBuffer.removeAll(keepingCapacity: true)
            return true
        }

        if installed {
            readSource.resume()
        } else {
            readSource.cancel()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(atPath: socketPath)
            throw CancellationError()
        }
    }

    private func connectWithRetry(socketPath: String, process: Process) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            if process.isRunning { process.terminate() }
            throw Bento7zError.processError("Unix socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                throw Bento7zError.processError("Binary worker terminated during startup (status \(process.terminationStatus))")
            }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw Bento7zError.processError("Failed to create Unix socket")
            }

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connectResult == 0 {
                return fd
            }
            Darwin.close(fd)
            usleep(5_000) // 5 ms
        }

        if process.isRunning { process.terminate() }
        throw Bento7zError.processError("Timed out connecting to binary worker socket")
    }

    // MARK: - Socket I/O

    private func enqueueWrite(_ data: Data, on fd: Int32, requestID: UInt64?) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            let stillActive = self.lock.withLock { $0.socketFD == fd && !$0.isClosed }
            guard stillActive else {
                if let requestID {
                    self.failRequest(requestID: requestID, error: Bento7zError.processError("Worker socket closed before write"))
                }
                return
            }
            let ok = Self.writeAll(data: data, to: fd)
            if !ok {
                if let requestID {
                    self.failRequest(requestID: requestID, error: Bento7zError.processError("Failed writing to worker socket"))
                }
                self.handleDisconnect(forFD: fd, reason: "Socket write failed")
            }
        }
    }

    private static func writeAll(data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var totalWritten = 0
            let totalCount = rawBuffer.count
            while totalWritten < totalCount {
                let written = Darwin.write(fd, base.advanced(by: totalWritten), totalCount - totalWritten)
                if written > 0 {
                    totalWritten += written
                } else if written < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = Darwin.poll(&pfd, 1, 2000)
                        continue
                    }
                    return false
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func drainReadableSocket(fd: Int32) {
        var temp = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(fd, &temp, temp.count)
            if n > 0 {
                let frames = appendAndExtractFrames(bytes: temp, count: n)
                for frame in frames {
                    dispatchFrame(frame)
                }
            } else if n == 0 {
                handleDisconnect(forFD: fd, reason: "Worker socket closed")
                return
            } else {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { return }
                handleDisconnect(forFD: fd, reason: "Worker socket read error (\(err))")
                return
            }
        }
    }

    private func appendAndExtractFrames(bytes: [UInt8], count: Int) -> [Bento7zBinaryProtocol.Frame] {
        lock.withLock { state in
            state.readBuffer.append(bytes, count: count)
            var extracted: [Bento7zBinaryProtocol.Frame] = []

            while state.readBuffer.count >= Bento7zBinaryProtocol.headerSize {
                let start = state.readBuffer.startIndex
                let payloadLen = UInt32(state.readBuffer[start])
                    | (UInt32(state.readBuffer[start + 1]) << 8)
                    | (UInt32(state.readBuffer[start + 2]) << 16)
                    | (UInt32(state.readBuffer[start + 3]) << 24)

                guard payloadLen <= Bento7zBinaryProtocol.maxPayloadLength else {
                    state.readBuffer.removeAll()
                    break
                }

                let totalFrameSize = Bento7zBinaryProtocol.headerSize + Int(payloadLen)
                guard state.readBuffer.count >= totalFrameSize else { break }

                let rawType = state.readBuffer[start + 4]
                var reqID: UInt64 = 0
                for i in 0..<8 {
                    reqID |= UInt64(state.readBuffer[start + 5 + i]) << (UInt64(i) * 8)
                }

                let payloadStart = start + Bento7zBinaryProtocol.headerSize
                let payloadEnd = start + totalFrameSize
                let payload = Data(state.readBuffer[payloadStart..<payloadEnd])
                state.readBuffer.removeSubrange(start..<payloadEnd)

                if let msgType = Bento7zBinaryProtocol.ResponseType(rawValue: rawType) {
                    extracted.append(Bento7zBinaryProtocol.Frame(type: msgType, requestID: reqID, payload: payload))
                }
            }
            return extracted
        }
    }

    private func dispatchFrame(_ frame: Bento7zBinaryProtocol.Frame) {
        switch frame.type {
        case .progress:
            guard let handlers = lock.withLock({ $0.pending[frame.requestID] }) else { return }
            if let progress = try? Bento7zBinaryProtocol.decodeProgress(frame.payload) {
                handlers.onProgress?(progress)
            }
        case .listMeta:
            guard let handlers = lock.withLock({ $0.pending[frame.requestID] }) else { return }
            if let meta = try? Bento7zBinaryProtocol.decodeListMeta(frame.payload) {
                handlers.onListMeta?(meta)
            }
        case .listChunk:
            guard let handlers = lock.withLock({ $0.pending[frame.requestID] }) else { return }
            if let chunk = try? Bento7zBinaryProtocol.decodeListChunk(frame.payload) {
                handlers.onListChunk?(chunk)
            }
        case .result:
            guard let handlers = lock.withLock({ $0.pending.removeValue(forKey: frame.requestID) }) else { return }
            do {
                let result = try Bento7zBinaryProtocol.decodeResult(frame.payload)
                handlers.onComplete(.success(result))
            } catch {
                handlers.onComplete(.failure(error))
            }
        case .error:
            guard let handlers = lock.withLock({ $0.pending.removeValue(forKey: frame.requestID) }) else { return }
            do {
                let errPayload = try Bento7zBinaryProtocol.decodeError(frame.payload)
                if errPayload.code == "CANCELLED" {
                    handlers.onComplete(.failure(CancellationError()))
                } else {
                    handlers.onComplete(.failure(Bento7zError.mapError(code: errPayload.code, message: errPayload.message)))
                }
            } catch {
                handlers.onComplete(.failure(error))
            }
        case .pong:
            guard let handlers = lock.withLock({ $0.pending.removeValue(forKey: frame.requestID) }) else { return }
            handlers.onComplete(.success(Bento7zBinaryProtocol.ResultPayload(archiveDeleted: false, outputSize: 0)))
        }
    }

    private func cancelRequest(requestID: UInt64, slot: RequestSlot, hardKillFallback: Bool) {
        let shouldScheduleHardKill = lock.withLock { state -> Bool in
            slot.isCancelled = true
            guard slot.isRegistered, state.pending[requestID] != nil, !state.isClosed, state.socketFD >= 0 else {
                return false
            }
            let cancelFrame = Bento7zBinaryProtocol.encodeFrame(type: .cancel, requestID: requestID)
            enqueueWrite(cancelFrame, on: state.socketFD, requestID: nil)
            return hardKillFallback
        }
        if shouldScheduleHardKill {
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(450)) { [weak self] in
                guard let self else { return }
                let stillPending = self.lock.withLock { $0.pending[requestID] != nil }
                if stillPending {
                    self.shutdown(terminateProcess: true)
                }
            }
        }
    }

    private func failRequest(requestID: UInt64, error: Error) {
        let handlers = lock.withLock { $0.pending.removeValue(forKey: requestID) }
        handlers?.onComplete(.failure(error))
    }

    private func resetFailedConnection() {
        let old: (Process?, DispatchSourceRead?, String?) = lock.withLock { state in
            let proc = state.process
            let src = state.readSource
            let path = state.socketPath
            state.process = nil
            state.socketFD = -1
            state.readSource = nil
            state.socketPath = nil
            state.readBuffer.removeAll(keepingCapacity: false)
            return (proc, src, path)
        }
        old.1?.cancel()
        if let proc = old.0, proc.isRunning { proc.terminate() }
        if let path = old.2 { try? FileManager.default.removeItem(atPath: path) }
    }

    private func handleDisconnect(forProcess expectedProcess: Process? = nil, forFD expectedFD: Int32? = nil, reason: String) {
        let cleanup: (DispatchSourceRead?, String?, [CallHandlers])? = lock.withLock { state in
            if let expectedProcess, state.process !== expectedProcess {
                return nil
            }
            if let expectedFD, state.socketFD != expectedFD {
                return nil
            }
            let src = state.readSource
            let path = state.socketPath
            let pendingHandlers = Array(state.pending.values)
            state.process = nil
            state.socketFD = -1
            state.readSource = nil
            state.socketPath = nil
            state.pending.removeAll()
            state.readBuffer.removeAll(keepingCapacity: false)
            return (src, path, pendingHandlers)
        }

        guard let cleanup else { return }
        cleanup.0?.cancel()
        if let path = cleanup.1 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !cleanup.2.isEmpty {
            Self.logger.warning("Binary worker disconnected: \(reason, privacy: .public)")
            let err = Bento7zError.processError(reason)
            for handler in cleanup.2 {
                handler.onComplete(.failure(err))
            }
        }
    }
}

/// Manages one shared persistent interactive binary worker per `(binaryPath, libraryPath)` pair.
final class Bento7zInteractiveWorkerPool: @unchecked Sendable {
    static let shared = Bento7zInteractiveWorkerPool()

    private struct Key: Hashable {
        let binaryPath: String
        let libraryPath: String
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Key: Bento7zBinaryClient]())

    func client(binaryPath: String, libraryPath: String) -> Bento7zBinaryClient {
        let key = Key(binaryPath: binaryPath, libraryPath: libraryPath)
        return lock.withLock { clients in
            if let existing = clients[key] {
                return existing
            }
            let client = Bento7zBinaryClient(binaryPath: binaryPath, libraryPath: libraryPath, label: "interactive")
            clients[key] = client
            return client
        }
    }

    func shutdownAll() {
        let all = lock.withLock { clients -> [Bento7zBinaryClient] in
            let values = Array(clients.values)
            clients.removeAll()
            return values
        }
        for client in all {
            client.shutdown(terminateProcess: true)
        }
    }
}
