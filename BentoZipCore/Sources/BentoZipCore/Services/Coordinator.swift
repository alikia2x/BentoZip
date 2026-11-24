import SwiftUI
import Observation

@Observable
@MainActor
public class CompressionCoordinator {
    let engine: any ArchiveEngine
    var activeTask: Task<Void, Never>?
    var activeOperationID: UUID?
    weak var lastExtractProgressState: ProgressState?
    var lastExtractOpenWindow: (() -> Void)?
    var pendingExtractDestinationURL: URL?

    public init(engine: any ArchiveEngine = Bento7zEngine()) {
        self.engine = engine
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
            appState.navigationPath = []
            appState.selectedEntryIDs = []
            appState.needsPasswordPrompt = false
            appState.passwordPromptReason = nil
            appState.isPasswordRetryError = false
            appState.pendingPasswordArchiveURL = nil
            appState.pendingPasswordAction = nil
            appState.fileEntries = result.entries
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
        progressState: ProgressState? = nil,
        openWindow: OpenWindowAction
    ) async {
        await submitPassword(
            password,
            appState: appState,
            progressState: progressState,
            onOpenProgressWindow: { openWindow(id: "progress") }
        )
    }

    /// Retry browsing or extracting the pending encrypted archive with a user-supplied password.
    public func submitPassword(
        _ password: String,
        appState: AppState,
        progressState: ProgressState? = nil,
        onOpenProgressWindow: (() -> Void)? = nil
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
            let effectiveOpenWindow = onOpenProgressWindow ?? lastExtractOpenWindow
            await extract(
                appState: appState,
                progressState: effectiveProgressState,
                entries: entries,
                chooseDestination: chooseDestination,
                onOpenProgressWindow: effectiveOpenWindow
            )
        }
    }

    // MARK: - Progress & Task Helpers

    @discardableResult
    func prepareProgress(
        _ progressState: ProgressState,
        description: String,
        openProgressWindow: (() -> Void)?
    ) -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        progressState.reset(description: description)
        progressState.isOperationInProgress = true
        progressState.onCancel = { [weak self, weak progressState] in
            guard let self, let progressState else { return }
            self.cancelOperation(progressState: progressState)
        }
        openProgressWindow?()
        return operationID
    }

    func makeProgressHandler(
        operationID: UUID,
        progressState: ProgressState
    ) -> @Sendable (ArchiveProgress) -> Void {
        { [weak self, weak progressState] update in
            Task { @MainActor in
                guard let self,
                      let progressState,
                      self.activeOperationID == operationID,
                      progressState.isOperationInProgress else {
                    return
                }
                Self.applyProgress(update, to: progressState)
            }
        }
    }

    func runManagedTask(
        operationID: UUID,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
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
        afterCompletion: () -> Void = {}
    ) async {
        progressState.operationProgress = 1.0
        progressState.isOperationInProgress = false
        afterCompletion()
        try? await Task.sleep(for: .milliseconds(250))
        progressState.shouldDismiss = true
    }

    func abortProgress(_ progressState: ProgressState) {
        progressState.isOperationInProgress = false
        progressState.currentFileName = ""
        progressState.shouldDismiss = true
    }

    func refreshArchiveContents(
        at archiveURL: URL,
        password: String?,
        into appState: AppState
    ) async throws {
        let refreshed = try await engine.listArchive(in: archiveURL, password: password)
        appState.fileEntries = refreshed.entries
        appState.archivePackedSize = refreshed.archivePackedSize
        appState.navigationPath = []
        appState.selectedEntryIDs = []
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
