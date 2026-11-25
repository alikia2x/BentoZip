import Foundation
import Observation

@Observable
@MainActor
public class CompressionCoordinator {
    let engine: any ArchiveEngine
    public let transferManager: TransferManager
    var activeTask: Task<Void, Never>?
    var activeOperationID: UUID?
    var activeTransferTask: TransferTask?
    weak var lastExtractProgressState: ProgressState?
    var pendingExtractDestinationURL: URL?

    public init(
        engine: any ArchiveEngine = Bento7zEngine(),
        transferManager: TransferManager? = nil
    ) {
        self.engine = engine
        self.transferManager = transferManager ?? .shared
    }

    // MARK: - Cancellation

    public func cancelOperation(progressState: ProgressState) {
        activeOperationID = nil
        activeTask?.cancel()
        activeTask = nil
        abortProgress(progressState)
    }

    // MARK: - Browse Archive

    public func browseArchive(
        at url: URL,
        password: String? = nil,
        appState: AppState
    ) async {
        guard activeTask == nil, !appState.isLoading else { return }

        pendingExtractDestinationURL = nil
        appState.lastError = nil
        appState.isLoading = true

        do {
            let result = try await engine.listArchive(in: url, password: password)
            appState.mode = .browseArchive
            appState.sourceArchiveURL = url
            appState.archivePassword = password
            appState.archivePackedSize = result.archivePackedSize
            appState.clearNavigationAndSelection()
            appState.cancelPasswordPrompt()
            appState.setEntries(result.entries)
            appState.isLoading = false
            appState.preferencesManager?.recordArchive(url.path)
        } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
            appState.isLoading = false
            presentPasswordPrompt(for: url, action: .browse(url), error: error, in: appState)
        } catch {
            appState.isLoading = false
            appState.reset()
            appState.lastError = String(localized: "Unable to read archive: \(error.localizedDescription)", bundle: .module)
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

    // MARK: - Progress & Task Helpers

    @discardableResult
    func prepareProgress(
        _ progressState: ProgressState,
        description: String,
        kind: TransferTask.Kind = .compress,
        totalBytes: Int64 = 0,
        totalFiles: Int? = nil,
        destinationURL: URL? = nil,
        sourceArchiveURL: URL? = nil
    ) -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        progressState.reset(description: description)
        progressState.isOperationInProgress = true

        let cancelHandler: () -> Void = { [weak self, weak progressState] in
            guard let self, let progressState else { return }
            self.cancelOperation(progressState: progressState)
        }
        progressState.onCancel = cancelHandler

        if let previous = activeTransferTask {
            transferManager.remove(id: previous.id)
        }
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
        activeTransferTask = transferTask
        transferManager.register(transferTask)

        return operationID
    }

    func makeProgressHandler(
        operationID: UUID,
        progressState: ProgressState
    ) -> @Sendable (ArchiveProgress) -> Void {
        let transferTask = activeTransferTask
        return { [weak self, weak progressState, weak transferTask] update in
            Task { @MainActor in
                guard let self,
                      let progressState,
                      self.activeOperationID == operationID,
                      progressState.isOperationInProgress else {
                    return
                }
                Self.applyProgress(update, to: progressState)
                transferTask?.apply(update)
            }
        }
    }

    func runManagedTask(
        operationID: UUID,
        progressState: ProgressState,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
                }
                if progressState.isOperationInProgress {
                    self.abortProgress(progressState)
                } else if let transfer = self.activeTransferTask, transfer.id == operationID {
                    self.transferManager.remove(id: operationID)
                    self.activeTransferTask = nil
                }
            }
            await work()
        }
        activeTask = task
        await task.value
        activeTask = nil
    }

    func completeProgress(
        _ progressState: ProgressState,
        operationID: UUID,
        finalOutputURL: URL? = nil,
        afterCompletion: () -> Void = {}
    ) async {
        if activeOperationID == operationID {
            activeOperationID = nil
        }
        progressState.operationProgress = 1.0
        progressState.isCancellable = false
        progressState.onCancel = nil

        var finalSize: Int64?
        if let finalOutputURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: finalOutputURL.path) {
            finalSize = (attrs[.size] as? NSNumber)?.int64Value
        }
        activeTransferTask?.markCompleted(finalOutputSize: finalSize)

        afterCompletion()
        if !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(180))
        }
        progressState.isOperationInProgress = false
        if activeTransferTask?.id == operationID {
            transferManager.remove(id: operationID)
            activeTransferTask = nil
        } else {
            transferManager.remove(id: operationID)
        }
    }

    func abortProgress(_ progressState: ProgressState) {
        progressState.isOperationInProgress = false
        progressState.currentFileName = ""
        progressState.onCancel = nil
        if let transfer = activeTransferTask {
            transferManager.remove(id: transfer.id)
            activeTransferTask = nil
        }
    }

    func refreshArchiveContents(
        at archiveURL: URL,
        password: String?,
        into appState: AppState
    ) async throws {
        let refreshed = try await engine.listArchive(in: archiveURL, password: password)
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

    private static func applyProgress(_ update: ArchiveProgress, to progressState: ProgressState) {
        progressState.operationProgress = update.fractionCompleted
        if let file = update.currentFile, !file.isEmpty {
            progressState.currentFileName = (file as NSString).lastPathComponent
        }
    }
}
