import AppKit

extension CompressionCoordinator {

    // MARK: - Compress

    public func compress(
        appState: AppState,
        progressState: ProgressState
    ) async {
        guard activeTask == nil,
              appState.mode == .compress,
              !appState.rootNodes.isEmpty else { return }

        var settings = appState.compressionSettings
        if !appState.excludedCompressRelativePaths.isEmpty {
            let existing = Set(settings.exclusionPatterns)
            let extra = appState.excludedCompressRelativePaths.sorted().filter { !existing.contains($0) }
            settings.exclusionPatterns.append(contentsOf: extra)
        }
        let sourceURLs = appState.rootNodes.map(\.url)
        guard let saveURL = resolveCompressSaveURL(sourceURLs: sourceURLs, settings: settings) else { return }

        let operationID = prepareProgress(
            progressState,
            description: String(localized: "Compressing…", bundle: .module),
            kind: .compress,
            totalBytes: appState.totalSize,
            destinationURL: saveURL
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID, progressState: progressState) {
            do {
                try await self.engine.create(
                    from: sourceURLs,
                    to: saveURL,
                    settings: settings,
                    onProgress: progressHandler
                )
                try Task.checkCancellation()

                await self.completeProgress(progressState, operationID: operationID, finalOutputURL: saveURL) {
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
        chooseDestination: Bool = false
    ) async {
        guard activeTask == nil,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        lastExtractProgressState = progressState

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

        let estimatedBytes: Int64 = if let entries, !entries.isEmpty {
            entries.reduce(0) { $0 + $1.size }
        } else {
            appState.totalSize
        }
        let estimatedFiles: Int? = if let entries, !entries.isEmpty {
            entries.count
        } else {
            appState.totalEntryCount > 0 ? appState.totalEntryCount : nil
        }
        let operationID = prepareProgress(
            progressState,
            description: String(localized: "Extracting…", bundle: .module),
            kind: .extract,
            totalBytes: estimatedBytes,
            totalFiles: estimatedFiles,
            destinationURL: destinationURL,
            sourceArchiveURL: archiveURL
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID, progressState: progressState) {
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

                await self.completeProgress(progressState, operationID: operationID) {
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
        progressState: ProgressState
    ) async {
        guard activeTask == nil, appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL, !urls.isEmpty else { return }

        let password = appState.archivePassword
        let operationID = prepareProgress(
            progressState,
            description: String(localized: "Adding to archive…", bundle: .module),
            kind: .addEntries,
            totalFiles: urls.count,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )
        let progressHandler = makeProgressHandler(operationID: operationID, progressState: progressState)

        await runManagedTask(operationID: operationID, progressState: progressState) {
            do {
                try await self.engine.addEntries(to: archiveURL, from: urls, password: password, onProgress: progressHandler)
                DragDropManager.shared.invalidateCache(for: archiveURL)
                try Task.checkCancellation()
                try await self.refreshArchiveContents(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeProgress(progressState, operationID: operationID)
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
        progressState: ProgressState
    ) async {
        guard activeTask == nil, appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL, !entries.isEmpty else { return }

        let password = appState.archivePassword
        let operationID = prepareProgress(
            progressState,
            description: String(localized: "Removing items…", bundle: .module),
            kind: .removeEntries,
            totalFiles: entries.count,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(operationID: operationID, progressState: progressState) {
            do {
                try await self.engine.removeEntries(from: archiveURL, entries: entries, password: password)
                DragDropManager.shared.invalidateCache(for: archiveURL)
                try Task.checkCancellation()
                if !FileManager.default.fileExists(atPath: archiveURL.path) {
                    appState.reset()
                } else {
                    try await self.refreshArchiveContents(at: archiveURL, password: password, into: appState)
                }
                appState.lastError = nil
                await self.completeProgress(progressState, operationID: operationID)
            } catch is CancellationError {
                self.abortProgress(progressState)
            } catch {
                self.abortProgress(progressState)
                appState.lastError = String(localized: "Failed to remove items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }
}
