import SwiftUI
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
public class CompressionCoordinator {
    private let engine: any ArchiveEngine
    private var activeTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private weak var lastExtractProgressState: ProgressState?
    private var lastExtractOpenWindow: (() -> Void)?
    private var pendingExtractDestinationURL: URL?

    public init(engine: any ArchiveEngine = Bento7zEngine()) {
        self.engine = engine
    }

    // MARK: - Cancellation

    public func cancelOperation(progressState: ProgressState) {
        activeOperationID = nil
        activeTask?.cancel()
        activeTask = nil
        progressState.isOperationInProgress = false
        progressState.currentFileName = ""
        progressState.shouldDismiss = true
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
            appState.pendingPasswordArchiveURL = url
            appState.pendingPasswordAction = .browse(url)
            appState.isPasswordRetryError = (error == .wrongPassword)
            appState.needsPasswordPrompt = true
            appState.passwordPromptReason = error.localizedDescription
        } catch {
            appState.isLoading = false
            appState.reset()
            appState.lastError = "无法读取压缩包: \(error.localizedDescription)"
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

    // MARK: - Compress

    public func compress(
        appState: AppState,
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await compress(
            appState: appState,
            progressState: progressState,
            onOpenProgressWindow: { openWindow(id: "progress") }
        )
    }

    public func compress(
        appState: AppState,
        progressState: ProgressState,
        onOpenProgressWindow: (() -> Void)? = nil
    ) async {
        guard activeTask == nil,
              appState.mode == .compress,
              !appState.fileEntries.isEmpty else { return }

        let settings = appState.compressionSettings
        let sourceURLs = appState.fileEntries.map(\.url)

        guard let saveURL = resolveCompressSaveURL(sourceURLs: sourceURLs, settings: settings) else {
            return
        }

        let operationID = prepareProgress(
            progressState,
            description: "正在压缩...",
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
                }
            }
            do {
                try await engine.create(
                    from: sourceURLs,
                    to: saveURL,
                    settings: settings,
                    onProgress: progressHandler
                )

                try Task.checkCancellation()

                progressState.operationProgress = 1.0
                progressState.isOperationInProgress = false
                appState.lastError = nil
                appState.preferencesManager?.recordArchive(saveURL.path)

                try? await Task.sleep(for: .milliseconds(250))
                progressState.shouldDismiss = true

                if appState.revealInFinderAfterExtract {
                    NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: saveURL)
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
            } catch {
                try? FileManager.default.removeItem(at: saveURL)
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
                appState.lastError = "压缩失败: \(error.localizedDescription)"
            }
        }

        activeTask = task
        await task.value
        activeTask = nil
    }

    // MARK: - Extract

    public func extract(
        appState: AppState,
        progressState: ProgressState,
        entries: [FileEntry]? = nil,
        chooseDestination: Bool = false,
        openWindow: OpenWindowAction
    ) async {
        await extract(
            appState: appState,
            progressState: progressState,
            entries: entries,
            chooseDestination: chooseDestination,
            onOpenProgressWindow: { openWindow(id: "progress") }
        )
    }

    public func extract(
        appState: AppState,
        progressState: ProgressState,
        entries: [FileEntry]? = nil,
        chooseDestination: Bool = false,
        onOpenProgressWindow: (() -> Void)? = nil
    ) async {
        guard activeTask == nil,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        lastExtractProgressState = progressState
        lastExtractOpenWindow = onOpenProgressWindow

        let destinationURL: URL
        if chooseDestination,
           case .extract(let pendingURL, _, true) = appState.pendingPasswordAction,
           pendingURL == archiveURL,
           let savedDestination = pendingExtractDestinationURL {
            destinationURL = savedDestination
        } else if let resolved = resolveExtractDestinationURL(
            archiveURL: archiveURL,
            chooseDestination: chooseDestination
        ) {
            destinationURL = resolved
        } else {
            return
        }

        let password = appState.archivePassword
        let shouldUnwrap = appState.unwrapSingleTopDirectory
        let shouldReveal = appState.revealInFinderAfterExtract
        let destinationExistedBefore = FileManager.default.fileExists(atPath: destinationURL.path)

        let operationID = prepareProgress(
            progressState,
            description: "正在解压...",
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
                }
            }
            do {
                try await engine.extract(
                    archiveURL: archiveURL,
                    entries: entries,
                    to: destinationURL,
                    password: password,
                    onProgress: progressHandler
                )

                try Task.checkCancellation()

                if shouldUnwrap && (entries == nil || entries?.isEmpty == true) {
                    await Self.unwrapSingleTopDirectory(at: destinationURL)
                }

                try Task.checkCancellation()

                progressState.operationProgress = 1.0
                progressState.isOperationInProgress = false
                appState.lastError = nil
                appState.needsPasswordPrompt = false
                appState.passwordPromptReason = nil
                appState.isPasswordRetryError = false
                appState.pendingPasswordArchiveURL = nil
                appState.pendingPasswordAction = nil
                pendingExtractDestinationURL = nil

                try? await Task.sleep(for: .milliseconds(250))
                progressState.shouldDismiss = true

                if shouldReveal {
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            } catch is CancellationError {
                if !destinationExistedBefore {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                pendingExtractDestinationURL = nil
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                if !destinationExistedBefore {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                if error == .wrongPassword {
                    appState.archivePassword = nil
                }
                if chooseDestination {
                    pendingExtractDestinationURL = destinationURL
                }
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
                appState.pendingPasswordArchiveURL = archiveURL
                appState.pendingPasswordAction = .extract(
                    archiveURL,
                    entries: entries,
                    chooseDestination: chooseDestination
                )
                appState.isPasswordRetryError = (error == .wrongPassword)
                appState.needsPasswordPrompt = true
                appState.passwordPromptReason = error.localizedDescription
            } catch {
                if !destinationExistedBefore {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                pendingExtractDestinationURL = nil
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
                appState.lastError = "解压失败: \(error.localizedDescription)"
            }
        }

        activeTask = task
        await task.value
        activeTask = nil
    }

    // MARK: - Mutate Existing Archive

    public func addEntries(
        appState: AppState,
        urls: [URL],
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await addEntries(
            appState: appState,
            urls: urls,
            progressState: progressState,
            onOpenProgressWindow: { openWindow(id: "progress") }
        )
    }

    public func addEntries(
        appState: AppState,
        urls: [URL],
        progressState: ProgressState,
        onOpenProgressWindow: (() -> Void)? = nil
    ) async {
        guard activeTask == nil,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL,
              !urls.isEmpty else { return }

        let password = appState.archivePassword
        let operationID = prepareProgress(
            progressState,
            description: "正在添加到压缩包...",
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
                }
            }
            do {
                try await engine.addEntries(
                    to: archiveURL,
                    from: urls,
                    password: password,
                    onProgress: progressHandler
                )

                try Task.checkCancellation()

                let refreshed = try await engine.listArchive(in: archiveURL, password: password)
                appState.fileEntries = refreshed.entries
                appState.archivePackedSize = refreshed.archivePackedSize
                appState.navigationPath = []
                appState.selectedEntryIDs = []
                appState.lastError = nil

                progressState.operationProgress = 1.0
                progressState.isOperationInProgress = false
                try? await Task.sleep(for: .milliseconds(250))
                progressState.shouldDismiss = true
            } catch is CancellationError {
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
            } catch {
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
                appState.lastError = "添加失败: \(error.localizedDescription)"
            }
        }

        activeTask = task
        await task.value
        activeTask = nil
    }

    public func removeEntries(
        appState: AppState,
        entries: [FileEntry],
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await removeEntries(
            appState: appState,
            entries: entries,
            progressState: progressState,
            onOpenProgressWindow: { openWindow(id: "progress") }
        )
    }

    public func removeEntries(
        appState: AppState,
        entries: [FileEntry],
        progressState: ProgressState,
        onOpenProgressWindow: (() -> Void)? = nil
    ) async {
        guard activeTask == nil,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL,
              !entries.isEmpty else { return }

        let password = appState.archivePassword
        let operationID = prepareProgress(
            progressState,
            description: "正在删除条目...",
            openProgressWindow: onOpenProgressWindow
        )

        let task = Task { @MainActor in
            defer {
                if self.activeOperationID == operationID {
                    self.activeOperationID = nil
                }
            }
            do {
                try await engine.removeEntries(from: archiveURL, entries: entries, password: password)
                try Task.checkCancellation()

                if !FileManager.default.fileExists(atPath: archiveURL.path) {
                    appState.reset()
                } else {
                    let refreshed = try await engine.listArchive(in: archiveURL, password: password)
                    appState.fileEntries = refreshed.entries
                    appState.archivePackedSize = refreshed.archivePackedSize
                    appState.navigationPath = []
                    appState.selectedEntryIDs = []
                }
                appState.lastError = nil

                progressState.operationProgress = 1.0
                progressState.isOperationInProgress = false
                try? await Task.sleep(for: .milliseconds(250))
                progressState.shouldDismiss = true
            } catch is CancellationError {
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
            } catch {
                progressState.isOperationInProgress = false
                progressState.currentFileName = ""
                progressState.shouldDismiss = true
                appState.lastError = "删除失败: \(error.localizedDescription)"
            }
        }

        activeTask = task
        await task.value
        activeTask = nil
    }

    // MARK: - Private Helpers

    @discardableResult
    private func prepareProgress(
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

    private func makeProgressHandler(
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

    private static func applyProgress(_ update: ArchiveProgress, to progressState: ProgressState) {
        progressState.operationProgress = update.fractionCompleted
        if let file = update.currentFile, !file.isEmpty {
            progressState.currentFileName = (file as NSString).lastPathComponent
        }
    }

    private func resolveCompressSaveURL(sourceURLs: [URL], settings: CompressionSettings) -> URL? {
        let fallbackStem = AppState.defaultArchiveStem(for: sourceURLs)
        let archiveName = PathUtils.normalizedArchiveFileName(
            settings.archiveName,
            format: settings.format,
            fallbackStem: fallbackStem
        )

        if PathUtils.allShareParentDirectory(sourceURLs), let first = sourceURLs.first {
            let parent = first.deletingLastPathComponent()
            let proposed = parent.appendingPathComponent(archiveName)
            return PathUtils.uniqueFileURL(for: proposed)
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = archiveName
        panel.allowedContentTypes = [.archive, .data]
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    private func resolveExtractDestinationURL(archiveURL: URL, chooseDestination: Bool) -> URL? {
        let folderName = PathUtils.splitArchiveName(archiveURL.lastPathComponent).stem
        let safeFolderName = folderName.isEmpty ? "Extracted" : folderName

        if chooseDestination {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "解压到此处"
            let response = panel.runModal()
            guard response == .OK, let chosenDir = panel.url else { return nil }
            let proposed = chosenDir.appendingPathComponent(safeFolderName)
            return PathUtils.uniqueFileURL(for: proposed)
        }

        let parent = archiveURL.deletingLastPathComponent()
        let proposed = parent.appendingPathComponent(safeFolderName)
        return PathUtils.uniqueFileURL(for: proposed)
    }

    private nonisolated static func unwrapSingleTopDirectory(at url: URL) async {
        await Task.detached(priority: .userInitiated) {
            unwrapSingleTopDirectorySync(at: url)
        }.value
    }

    private nonisolated static func unwrapSingleTopDirectorySync(at url: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []),
              contents.count == 1 else { return }

        let wrapper = contents[0]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: wrapper.path, isDirectory: &isDir), isDir.boolValue else { return }

        // Rename wrapper first so a child with the exact same name as wrapper can still move cleanly.
        let stagingWrapper = url.appendingPathComponent(".bentozip_unwrap_\(UUID().uuidString)")
        do {
            try fm.moveItem(at: wrapper, to: stagingWrapper)
            let children = try fm.contentsOfDirectory(at: stagingWrapper, includingPropertiesForKeys: nil, options: [])
            for child in children {
                let target = url.appendingPathComponent(child.lastPathComponent)
                try fm.moveItem(at: child, to: target)
            }
            try fm.removeItem(at: stagingWrapper)
        } catch {
            // Best-effort rollback if staging failed halfway
            if fm.fileExists(atPath: stagingWrapper.path) && !fm.fileExists(atPath: wrapper.path) {
                try? fm.moveItem(at: stagingWrapper, to: wrapper)
            }
        }
    }
}
