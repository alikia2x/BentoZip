import Foundation
import Observation
import os

/// Coalesces high-frequency engine progress/file callbacks off the main actor (~20 Hz)
/// so extracting or compressing 100,000+ small files never floods `@MainActor` while keeping exact file counts.
private final class ProgressCoalescer: @unchecked Sendable {
    private struct Pending {
        var latest: ArchiveProgress?
        var accumulatedFileDelta: Int = 0
        var lastFlushTime: ContinuousClock.Instant?
        var isScheduled: Bool = false
        var isStopped: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: Pending())
    private let minInterval: Duration
    private let onFlush: @MainActor (ArchiveProgress) -> Void

    init(minInterval: Duration = .milliseconds(50), onFlush: @escaping @MainActor (ArchiveProgress) -> Void) {
        self.minInterval = minInterval
        self.onFlush = onFlush
    }

    func receive(_ update: ArchiveProgress) {
        let now = ContinuousClock.now
        let action: (immediate: ArchiveProgress?, scheduleDelay: Duration?) = lock.withLock { state in
            guard !state.isStopped else { return (nil, nil) }
            let delta = update.fileCountDelta > 0 ? update.fileCountDelta : (update.isFileEvent ? 1 : 0)
            state.accumulatedFileDelta += delta

            let merged = ArchiveProgress(
                fractionCompleted: update.fractionCompleted,
                currentFile: update.currentFile ?? state.latest?.currentFile,
                processedBytes: update.processedBytes ?? state.latest?.processedBytes,
                totalBytes: update.totalBytes ?? state.latest?.totalBytes,
                isFileEvent: state.accumulatedFileDelta > 0,
                fileCountDelta: state.accumulatedFileDelta
            )

            let shouldFlushNow: Bool
            if update.fractionCompleted >= 1.0 {
                shouldFlushNow = true
            } else if let last = state.lastFlushTime {
                shouldFlushNow = (now - last) >= minInterval
            } else {
                shouldFlushNow = true
            }

            if shouldFlushNow {
                state.latest = nil
                state.accumulatedFileDelta = 0
                state.lastFlushTime = now
                return (merged, nil)
            }

            state.latest = merged
            if !state.isScheduled {
                state.isScheduled = true
                let remaining = state.lastFlushTime.map { minInterval - (now - $0) } ?? minInterval
                return (nil, remaining > .zero ? remaining : .milliseconds(10))
            }
            return (nil, nil)
        }

        if let immediate = action.immediate {
            Task { @MainActor [onFlush] in onFlush(immediate) }
        } else if let delay = action.scheduleDelay {
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(for: delay)
                self?.flushPending()
            }
        }
    }

    func stop() {
        lock.withLock { state in
            state.isStopped = true
            state.latest = nil
            state.accumulatedFileDelta = 0
        }
    }

    private func flushPending() {
        let pending: ArchiveProgress? = lock.withLock { state in
            state.isScheduled = false
            guard !state.isStopped, let latest = state.latest else { return nil }
            let merged = ArchiveProgress(
                fractionCompleted: latest.fractionCompleted,
                currentFile: latest.currentFile,
                processedBytes: latest.processedBytes,
                totalBytes: latest.totalBytes,
                isFileEvent: state.accumulatedFileDelta > 0,
                fileCountDelta: state.accumulatedFileDelta
            )
            state.latest = nil
            state.accumulatedFileDelta = 0
            state.lastFlushTime = ContinuousClock.now
            return merged
        }

        if let pending {
            Task { @MainActor [onFlush] in onFlush(pending) }
        }
    }
}

@Observable
@MainActor
public class CompressionCoordinator {
    let engine: any ArchiveEngine
    public let transferManager: TransferManager

    struct ManagedOperation {
        let id: UUID
        let task: Task<Void, Never>
        let transferTask: TransferTask
        weak var progressState: ProgressState?
        fileprivate let coalescer: ProgressCoalescer
    }

    var activeOperations: [UUID: ManagedOperation] = [:]
    private var browseTask: Task<Void, Never>?
    private var browseGeneration: UInt64 = 0
    weak var lastExtractProgressState: ProgressState?
    var pendingExtractDestinationURL: URL?

    public init(
        engine: any ArchiveEngine = Bento7zEngine(),
        transferManager: TransferManager? = nil
    ) {
        self.engine = engine
        self.transferManager = transferManager ?? .shared
    }

    // MARK: - Cancellation & Detachment

    /// Cancel only an in-flight archive listing for this window (leaves running compress/extract tasks untouched).
    public func cancelBrowse() {
        browseGeneration &+= 1
        browseTask?.cancel()
        browseTask = nil
    }

    /// Detach a window's `ProgressState` when navigating back to Home so the window is immediately usable
    /// while any already-started transfer continues running in the standalone Tasks window.
    public func detachWindowProgress(_ progressState: ProgressState) {
        progressState.isOperationInProgress = false
        progressState.currentFileName = ""
        progressState.onCancel = nil
        for (id, var op) in activeOperations where op.progressState === progressState {
            op.progressState = nil
            activeOperations[id] = op
        }
    }

    public func cancelOperation(id: UUID) {
        guard let op = activeOperations.removeValue(forKey: id) else { return }
        op.coalescer.stop()
        op.task.cancel()
        transferManager.remove(id: id)
        if let progressState = op.progressState {
            resetWindowProgress(progressState)
        }
    }

    public func cancelOperation(progressState: ProgressState) {
        let matchingIDs = activeOperations.values
            .filter { $0.progressState === progressState }
            .map(\.id)
        for id in matchingIDs {
            cancelOperation(id: id)
        }
        resetWindowProgress(progressState)
    }

    // MARK: - Browse Archive (Instant UI + Cancellable Background Listing)

    public func browseArchive(
        at url: URL,
        password: String? = nil,
        appState: AppState
    ) async {
        browseGeneration &+= 1
        let generation = browseGeneration
        browseTask?.cancel()

        pendingExtractDestinationURL = nil
        appState.lastError = nil
        appState.mode = .browseArchive
        appState.sourceArchiveURL = url
        appState.archivePackedSize = nil
        appState.clearNavigationAndSelection()
        appState.setEntries([])
        appState.isLoading = true

        let task = Task { @MainActor in
            do {
                let result = try await engine.listArchive(in: url, password: password)
                guard !Task.isCancelled, self.browseGeneration == generation else { return }
                appState.mode = .browseArchive
                appState.sourceArchiveURL = url
                appState.archivePassword = password
                appState.archivePackedSize = result.archivePackedSize
                appState.clearNavigationAndSelection()
                appState.cancelPasswordPrompt()
                appState.setEntries(result.entries)
                appState.isLoading = false
                appState.preferencesManager?.recordArchive(url.path)
            } catch is CancellationError {
                if self.browseGeneration == generation {
                    appState.isLoading = false
                }
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                guard !Task.isCancelled, self.browseGeneration == generation else { return }
                appState.isLoading = false
                presentPasswordPrompt(for: url, action: .browse(url), error: error, in: appState)
            } catch {
                guard !Task.isCancelled, self.browseGeneration == generation else { return }
                appState.isLoading = false
                appState.reset()
                appState.lastError = String(localized: "Unable to read archive: \(error.localizedDescription)", bundle: .module)
            }
        }
        browseTask = task
        await task.value
        if browseGeneration == generation {
            browseTask = nil
        }
    }

    /// Retry browsing or extracting the pending encrypted archive with a user-supplied password.
    public func submitPassword(
        _ password: String,
        appState: AppState,
        progressState: ProgressState? = nil
    ) async {
        let fallbackURL = appState.pendingPasswordArchiveURL ?? appState.sourceArchiveURL
        let action = appState.pendingPasswordAction ?? fallbackURL.map { .browse($0) }
        guard let action else { return }

        switch action {
        case .browse(let targetURL):
            await browseArchive(at: targetURL, password: password, appState: appState)

        case .extract(let targetURL, let entries, let chooseDestination):
            appState.mode = .browseArchive
            appState.sourceArchiveURL = targetURL
            appState.archivePassword = password
            appState.needsPasswordPrompt = false
            let effectiveProgressState = progressState ?? lastExtractProgressState ?? ProgressState()
            await extract(
                appState: appState,
                progressState: effectiveProgressState,
                entries: entries,
                chooseDestination: chooseDestination
            )
        }
    }

    // MARK: - Progress & Detached Task Helpers

    struct OperationContext {
        let id: UUID
        let transferTask: TransferTask
        fileprivate let coalescer: ProgressCoalescer
        let progressHandler: @Sendable (ArchiveProgress) -> Void
    }

    func startOperation(
        progressState: ProgressState,
        description: String,
        kind: TransferTask.Kind,
        totalBytes: Int64 = 0,
        totalFiles: Int? = nil,
        destinationURL: URL? = nil,
        sourceArchiveURL: URL? = nil
    ) -> OperationContext {
        let operationID = UUID()
        progressState.reset(description: description)
        progressState.isOperationInProgress = true

        let cancelHandler: () -> Void = { [weak self] in
            self?.cancelOperation(id: operationID)
        }
        progressState.onCancel = cancelHandler

        let transferTask = TransferTask(
            id: operationID,
            kind: kind,
            title: description,
            totalBytes: totalBytes,
            totalFiles: totalFiles,
            destinationURL: destinationURL,
            sourceArchiveURL: sourceArchiveURL
        )
        transferTask.onCancel = cancelHandler
        transferManager.register(transferTask)

        let coalescer = ProgressCoalescer { [weak self, weak transferTask] update in
            guard let self, let op = self.activeOperations[operationID] else { return }
            transferTask?.apply(update)
            if let windowProgress = op.progressState, windowProgress.isOperationInProgress {
                Self.applyProgress(update, to: windowProgress)
            }
        }

        let handler: @Sendable (ArchiveProgress) -> Void = { update in
            coalescer.receive(update)
        }

        return OperationContext(
            id: operationID,
            transferTask: transferTask,
            coalescer: coalescer,
            progressHandler: handler
        )
    }

    func runManagedTask(
        context: OperationContext,
        progressState: ProgressState,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let operationID = context.id
        let task = Task { @MainActor in
            defer {
                if let op = self.activeOperations.removeValue(forKey: operationID) {
                    op.coalescer.stop()
                    self.transferManager.remove(id: operationID)
                    if let windowProgress = op.progressState, windowProgress.isOperationInProgress {
                        self.resetWindowProgress(windowProgress)
                    }
                }
            }
            await work()
        }

        activeOperations[operationID] = ManagedOperation(
            id: operationID,
            task: task,
            transferTask: context.transferTask,
            progressState: progressState,
            coalescer: context.coalescer
        )
        await task.value
    }

    func completeOperation(
        _ operationID: UUID,
        finalOutputURL: URL? = nil,
        afterCompletion: () -> Void = {}
    ) async {
        guard let op = activeOperations.removeValue(forKey: operationID) else { return }
        op.coalescer.stop()

        var finalSize: Int64?
        if let finalOutputURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: finalOutputURL.path) {
            finalSize = (attrs[.size] as? NSNumber)?.int64Value
        }

        op.transferTask.markCompleted(finalOutputSize: finalSize)
        if let progressState = op.progressState {
            progressState.operationProgress = 1.0
            progressState.isCancellable = false
            progressState.onCancel = nil
        }

        afterCompletion()
        if !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(180))
        }
        if let progressState = op.progressState {
            progressState.isOperationInProgress = false
        }
        transferManager.remove(id: operationID)
    }

    func abortOperation(_ operationID: UUID) {
        if let op = activeOperations.removeValue(forKey: operationID) {
            op.coalescer.stop()
            if let progressState = op.progressState {
                resetWindowProgress(progressState)
            }
        }
        transferManager.remove(id: operationID)
    }

    func refreshArchiveContentsIfStillViewing(
        at archiveURL: URL,
        password: String?,
        into appState: AppState
    ) async throws {
        guard appState.mode == .browseArchive,
              appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL else {
            return
        }
        let refreshed = try await engine.listArchive(in: archiveURL, password: password)
        guard appState.mode == .browseArchive,
              appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL else {
            return
        }
        appState.clearNavigationAndSelection()
        appState.setEntries(refreshed.entries)
        appState.archivePackedSize = refreshed.archivePackedSize
    }

    func presentPasswordPrompt(
        for archiveURL: URL,
        action: PendingPasswordAction,
        error: Bento7zError,
        in appState: AppState
    ) {
        appState.pendingPasswordArchiveURL = archiveURL
        appState.pendingPasswordAction = action
        appState.isPasswordRetryError = (error == .wrongPassword)
        appState.needsPasswordPrompt = true
        appState.passwordPromptReason = error.localizedDescription
    }

    private func resetWindowProgress(_ progressState: ProgressState) {
        progressState.isOperationInProgress = false
        progressState.currentFileName = ""
        progressState.onCancel = nil
    }

    private static func applyProgress(_ update: ArchiveProgress, to progressState: ProgressState) {
        progressState.operationProgress = update.fractionCompleted
        if let file = update.currentFile, !file.isEmpty {
            progressState.currentFileName = (file as NSString).lastPathComponent
        }
    }
}
