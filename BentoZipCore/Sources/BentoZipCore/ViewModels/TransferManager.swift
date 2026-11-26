import Foundation
import Observation

/// Represents an active archive transfer (compression, extraction, or archive mutation)
/// displayed in the standalone macOS Progress window with optional 7-Zip-style live statistics.
@Observable
@MainActor
public final class TransferTask: Identifiable {
    public enum Kind: Sendable, Equatable {
        case compress
        case extract
        case addEntries
        case removeEntries
        case rename
        case createFolder
        case test
    }

    public let id: UUID
    public let kind: Kind
    public var title: String
    public var currentFileName: String = ""
    public var fractionCompleted: Double = 0.0
    public var stage: ArchiveProgress.Stage = .normal
    public var isCancellable: Bool = true
    public var isCompleted: Bool = false

    // Live statistics telemetry
    public let startedAt: Date
    public var elapsedSeconds: TimeInterval = 0
    public var processedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var processedFiles: Int = 0
    public var totalFiles: Int?
    public var compressedBytes: Int64?
    public var destinationURL: URL?
    public var sourceArchiveURL: URL?
    public var bytesPerSecond: Double = 0

    public var onCancel: (() -> Void)?

    private var lastSampleTime: Date
    private var lastSampleBytes: Int64 = 0
    private var hasReceivedStageEvent = false

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        totalBytes: Int64 = 0,
        totalFiles: Int? = nil,
        destinationURL: URL? = nil,
        sourceArchiveURL: URL? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.totalBytes = max(0, totalBytes)
        self.totalFiles = totalFiles
        self.destinationURL = destinationURL
        self.sourceArchiveURL = sourceArchiveURL
        self.startedAt = startedAt
        self.lastSampleTime = startedAt
    }

    /// Estimated remaining duration based on smoothed throughput and remaining bytes.
    public var estimatedRemainingSeconds: TimeInterval? {
        guard !isCompleted, bytesPerSecond > 1, totalBytes > processedBytes else { return nil }
        let remaining = Double(totalBytes - processedBytes) / bytesPerSecond
        guard remaining.isFinite, remaining >= 0 else { return nil }
        return remaining
    }

    /// Live compression ratio percentage (`compressed / processed * 100`) when compressing.
    public var compressionRatioPercent: Int? {
        guard let compressedBytes, compressedBytes > 0 else { return nil }
        let baseline = processedBytes > 0 ? processedBytes : totalBytes
        guard baseline > 0 else { return nil }
        return max(1, Int((Double(compressedBytes) / Double(baseline) * 100.0).rounded()))
    }

    public func cancel() {
        onCancel?()
    }

    public func apply(_ update: ArchiveProgress, now: Date = Date()) {
        let clampedFraction = min(max(update.fractionCompleted, 0.0), 1.0)
        fractionCompleted = max(fractionCompleted, clampedFraction)

        let isSyntheticCompletion =
            clampedFraction >= 1.0 &&
            update.processedBytes == nil &&
            update.totalBytes == nil &&
            update.currentFile == nil &&
            update.stage == .normal &&
            hasReceivedStageEvent

        if !isSyntheticCompletion {
            let stageChanged = hasReceivedStageEvent && update.stage != stage
            stage = update.stage
            hasReceivedStageEvent = true

            if let file = update.currentFile, !file.isEmpty {
                currentFileName = (file as NSString).lastPathComponent
            } else if stageChanged {
                currentFileName = ""
            }

            if update.fileCountDelta > 0 {
                processedFiles += update.fileCountDelta
            } else if update.isFileEvent {
                processedFiles += 1
            }

            if stageChanged {
                if let total = update.totalBytes, total > 0 {
                    totalBytes = total
                }
                let nextProcessed = max(0, update.processedBytes ?? 0)
                processedBytes = nextProcessed
                lastSampleTime = now
                lastSampleBytes = nextProcessed
                bytesPerSecond = 0
            } else {
                if let total = update.totalBytes, total > 0 {
                    totalBytes = total
                }
                if let processed = update.processedBytes, processed >= 0 {
                    let clamped = max(processedBytes, processed)
                    updateThroughput(newBytes: clamped, now: now)
                    processedBytes = clamped
                } else if totalBytes > 0 {
                    let estimated = Int64((Double(totalBytes) * fractionCompleted).rounded())
                    if estimated > processedBytes {
                        updateThroughput(newBytes: estimated, now: now)
                        processedBytes = estimated
                    }
                }
            }
        }
        elapsedSeconds = max(0, now.timeIntervalSince(startedAt))
    }

    public func tick(now: Date = Date(), polledOutputSize: Int64? = nil) {
        guard !isCompleted else { return }
        elapsedSeconds = max(0, now.timeIntervalSince(startedAt))
        if let polledOutputSize, polledOutputSize > 0 {
            compressedBytes = polledOutputSize
        }
        // Fallback average speed once enough time and bytes have accumulated
        if bytesPerSecond <= 0, elapsedSeconds >= 0.5, processedBytes > 0 {
            bytesPerSecond = Double(processedBytes) / elapsedSeconds
        }
    }

    public func markCompleted(now: Date = Date(), finalOutputSize: Int64? = nil) {
        fractionCompleted = 1.0
        isCompleted = true
        isCancellable = false
        onCancel = nil
        elapsedSeconds = max(0, now.timeIntervalSince(startedAt))
        if totalBytes > 0 {
            processedBytes = max(processedBytes, totalBytes)
        }
        if let finalOutputSize, finalOutputSize > 0 {
            compressedBytes = finalOutputSize
        }
    }

    private func updateThroughput(newBytes: Int64, now: Date) {
        let dt = now.timeIntervalSince(lastSampleTime)
        let deltaBytes = newBytes - lastSampleBytes
        guard dt >= 0.25, deltaBytes > 0 else { return }
        let instantRate = Double(deltaBytes) / dt
        if bytesPerSecond <= 0 {
            bytesPerSecond = instantRate
        } else {
            bytesPerSecond = bytesPerSecond * 0.65 + instantRate * 0.35
        }
        lastSampleTime = now
        lastSampleBytes = newBytes
    }
}

/// Manages active transfer tasks across all open windows for the standalone Progress window.
@Observable
@MainActor
public final class TransferManager {
    public static let shared = TransferManager()

    public private(set) var tasks: [TransferTask] = []
    public var hasActiveTasks: Bool { !tasks.isEmpty }

    private var tickerTask: Task<Void, Never>?

    public init() {}

    public func register(_ task: TransferTask) {
        tasks.removeAll { $0.id == task.id }
        tasks.append(task)
        startTickerIfNeeded()
    }

    public func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
        if tasks.isEmpty {
            stopTicker()
        }
    }

    public func cancelAll() {
        let snapshot = tasks
        for task in snapshot where task.isCancellable {
            task.cancel()
        }
    }

    private func startTickerIfNeeded() {
        guard tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { break }
                guard !self.tasks.isEmpty else {
                    self.tickerTask = nil
                    break
                }
                await self.tickActiveTasks()
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    private func tickActiveTasks() async {
        let now = Date()
        let compressPollTargets: [(UUID, URL)] = tasks.compactMap { task in
            guard !task.isCompleted, task.kind == .compress, let dest = task.destinationURL else {
                return nil
            }
            return (task.id, dest)
        }

        var outputSizes: [UUID: Int64] = [:]
        if !compressPollTargets.isEmpty {
            outputSizes = await Task.detached(priority: .utility) {
                var sizes: [UUID: Int64] = [:]
                let fm = FileManager.default
                for (id, url) in compressPollTargets {
                    if let attrs = try? fm.attributesOfItem(atPath: url.path),
                       let size = (attrs[.size] as? NSNumber)?.int64Value,
                       size > 0 {
                        sizes[id] = size
                    }
                }
                return sizes
            }.value
        }

        for task in tasks {
            task.tick(now: now, polledOutputSize: outputSizes[task.id])
        }
    }
}
