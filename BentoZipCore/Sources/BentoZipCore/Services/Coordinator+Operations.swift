import SwiftUI

extension CompressionCoordinator {

    // MARK: - Compress

    public func compress(
        appState: AppState,
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await compress(appState: appState, progressState: progressState, onOpenProgressWindow: { openWindow(id: "progress") })
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
        guard let saveURL = resolveCompressSaveURL(sourceURLs: sourceURLs, settings: settings) else { return }

        let operationID = prepareProgress(
            progressState,
            description: String(localized: "Compressing…", bundle: .module),
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID) {
            do {
                try await self.engine.create(
                    from: sourceURLs,
                    to: saveURL,
                    settings: settings,
                    onProgress: progressHandler
                )
                try Task.checkCancellation()

                await self.completeProgress(progressState) {
                    appState.lastError = nil
                    appState.preferencesManager?.recordArchive(saveURL.path)
                }

                if appState.revealInFinderAfterExtract {
                    NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: saveURL)
                self.abortProgress(progressState)
            } catch {
                try? FileManager.default.removeItem(at: saveURL)
                self.abortProgress(progressState)
                appState.lastError = String(localized: "Compression failed: \(error.localizedDescription)", bundle: .module)
            }
        }
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
        } else if let resolved = resolveExtractDestinationURL(archiveURL: archiveURL, chooseDestination: chooseDestination) {
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
            description: String(localized: "Extracting…", bundle: .module),
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID) {
            do {
                try await self.engine.extract(
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

                await self.completeProgress(progressState) {
                    appState.lastError = nil
                    appState.cancelPasswordPrompt()
                    self.pendingExtractDestinationURL = nil
                }

                if shouldReveal {
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            } catch is CancellationError {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.pendingExtractDestinationURL = nil
                self.abortProgress(progressState)
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                if error == .wrongPassword { appState.archivePassword = nil }
                if chooseDestination { self.pendingExtractDestinationURL = destinationURL }
                self.abortProgress(progressState)
                self.presentPasswordPrompt(
                    for: archiveURL,
                    action: .extract(archiveURL, entries: entries, chooseDestination: chooseDestination),
                    error: error,
                    in: appState
                )
            } catch {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.pendingExtractDestinationURL = nil
                self.abortProgress(progressState)
                appState.lastError = String(localized: "Extraction failed: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    // MARK: - Mutate Existing Archive

    public func addEntries(
        appState: AppState,
        urls: [URL],
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await addEntries(appState: appState, urls: urls, progressState: progressState, onOpenProgressWindow: { openWindow(id: "progress") })
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
            description: String(localized: "Adding to archive…", bundle: .module),
            openProgressWindow: onOpenProgressWindow
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID) {
            do {
                try await self.engine.addEntries(to: archiveURL, from: urls, password: password, onProgress: progressHandler)
                try Task.checkCancellation()
                try await self.refreshArchiveContents(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeProgress(progressState)
            } catch is CancellationError {
                self.abortProgress(progressState)
            } catch {
                self.abortProgress(progressState)
                appState.lastError = String(localized: "Failed to add items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func removeEntries(
        appState: AppState,
        entries: [FileEntry],
        progressState: ProgressState,
        openWindow: OpenWindowAction
    ) async {
        await removeEntries(appState: appState, entries: entries, progressState: progressState, onOpenProgressWindow: { openWindow(id: "progress") })
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
            description: String(localized: "Removing items…", bundle: .module),
            openProgressWindow: onOpenProgressWindow
        )

        await runManagedTask(operationID: operationID) {
            do {
                try await self.engine.removeEntries(from: archiveURL, entries: entries, password: password)
                try Task.checkCancellation()

                if !FileManager.default.fileExists(atPath: archiveURL.path) {
                    appState.reset()
                } else {
                    try await self.refreshArchiveContents(at: archiveURL, password: password, into: appState)
                }
                appState.lastError = nil
                await self.completeProgress(progressState)
            } catch is CancellationError {
                self.abortProgress(progressState)
            } catch {
                self.abortProgress(progressState)
                appState.lastError = String(localized: "Failed to remove items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }
}
