import AppKit

extension CompressionCoordinator {

    // MARK: - Compress

    public func compress(
        appState: AppState,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .compress,
              !appState.rootNodes.isEmpty else { return }

        var settings = appState.compressionSettings
        if !appState.excludedCompressRelativePaths.isEmpty {
            let existing = Set(settings.exclusionPatterns)
            let extra = appState.excludedCompressRelativePaths.sorted().filter { !existing.contains($0) }
            settings.exclusionPatterns.append(contentsOf: extra)
        }
        let sourceURLs = appState.rootNodes.map(\.url)
        let shouldReveal = appState.revealInFinderAfterExtract
        let preferencesManager = appState.preferencesManager
        guard let saveURL = resolveCompressSaveURL(sourceURLs: sourceURLs, settings: settings) else { return }

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Compressing…", bundle: .module),
            kind: .compress,
            totalBytes: appState.totalSize,
            destinationURL: saveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.create(
                    from: sourceURLs,
                    to: saveURL,
                    settings: settings,
                    onProgress: context.progressHandler
                )
                try Task.checkCancellation()

                let splitVolumes = (settings.volumeSizeBytes > 0)
                    ? Bento7zEngine.splitVolumeURLs(for: saveURL)
                    : []
                let primaryURL = splitVolumes.first ?? saveURL

                await self.completeOperation(context.id, finalOutputURL: primaryURL) {
                    appState.lastError = nil
                    preferencesManager?.recordArchive(primaryURL.path)
                }

                if shouldReveal {
                    NSWorkspace.shared.activateFileViewerSelecting([primaryURL])
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: saveURL)
                if settings.volumeSizeBytes > 0 {
                    Bento7zEngine.cleanupSplitVolumes(baseArchiveURL: saveURL)
                }
                self.abortOperation(context.id)
            } catch {
                try? FileManager.default.removeItem(at: saveURL)
                if settings.volumeSizeBytes > 0 {
                    Bento7zEngine.cleanupSplitVolumes(baseArchiveURL: saveURL)
                }
                self.abortOperation(context.id)
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
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        lastExtractProgressState = progressState

        let conflictPolicy = appState.extractConflictPolicy
        let destinationURL: URL
        if chooseDestination,
           case .extract(let pendingURL, _, true) = appState.pendingPasswordAction,
           pendingURL == archiveURL,
           let savedDestination = pendingExtractDestinationURL {
            destinationURL = savedDestination
        } else if let resolved = resolveExtractDestinationURL(
            archiveURL: archiveURL,
            chooseDestination: chooseDestination,
            entries: entries,
            conflictPolicy: conflictPolicy
        ) {
            destinationURL = resolved
        } else {
            return
        }

        let isFullExtract = (entries == nil || entries?.isEmpty == true)
        let password = appState.archivePassword
        let encodingName = appState.selectedEncoding.iconvName
        let shouldUnwrap = appState.unwrapSingleTopDirectory
        let shouldReveal = appState.revealInFinderAfterExtract
        let shouldTrashAfterExtract = isFullExtract && appState.moveArchiveToTrashAfterExtract
        let shouldCloseAfterExtract = isFullExtract && appState.closeWindowAfterExtract
        let destinationExistedBefore = Bento7zPathSafety.itemExists(at: destinationURL)

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

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Extracting…", bundle: .module),
            kind: .extract,
            totalBytes: estimatedBytes,
            totalFiles: estimatedFiles,
            destinationURL: destinationURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            var stagingDir: URL?
            defer {
                if let stagingDir {
                    try? FileManager.default.removeItem(at: stagingDir)
                }
            }

            do {
                let stage = try Self.makeStagingDirectory(for: destinationURL)
                stagingDir = stage

                try await self.engine.extract(
                    archiveURL: archiveURL,
                    entries: entries,
                    to: stage,
                    password: password,
                    encoding: encodingName,
                    onProgress: context.progressHandler
                )
                try Task.checkCancellation()

                if isFullExtract && shouldUnwrap {
                    await Self.unwrapSingleTopDirectory(at: stage)
                }
                try Task.checkCancellation()

                let mergeResult = try await self.mergeStagedContents(
                    from: stage,
                    into: destinationURL,
                    initialPolicy: conflictPolicy,
                    appState: appState
                )
                try Task.checkCancellation()

                let finalDestinationURL = mergeResult.finalDestinationURL
                let mergedURLs = mergeResult.mergedTopLevelURLs

                await self.completeOperation(context.id) {
                    appState.lastError = nil
                    if appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL {
                        appState.cancelPasswordPrompt()
                    }
                    self.pendingExtractDestinationURL = nil
                }

                if shouldReveal {
                    let revealTargets: [URL] = if !isFullExtract, !mergedURLs.isEmpty {
                        mergedURLs
                    } else if isFullExtract && !mergedURLs.isEmpty || Bento7zPathSafety.itemExists(at: finalDestinationURL) {
                        [finalDestinationURL]
                    } else {
                        []
                    }
                    if !revealTargets.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(revealTargets)
                    }
                }

                let isStillViewingSameArchive =
                    appState.mode == .browseArchive &&
                    appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL

                if shouldTrashAfterExtract {
                    await Self.trashArchiveAndSplitVolumes(at: archiveURL)
                    if isStillViewingSameArchive && !shouldCloseAfterExtract {
                        appState.reset()
                    }
                }

                if shouldCloseAfterExtract && isStillViewingSameArchive {
                    appState.onRequestCloseWindow?()
                }
            } catch is CancellationError {
                appState.activeConflictPrompt?.cancel()
                appState.activeConflictPrompt = nil
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.pendingExtractDestinationURL = nil
                self.abortOperation(context.id)
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                appState.activeConflictPrompt?.cancel()
                appState.activeConflictPrompt = nil
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                if error == .wrongPassword && appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL {
                    appState.archivePassword = nil
                }
                if chooseDestination { self.pendingExtractDestinationURL = destinationURL }
                self.abortOperation(context.id)
                self.presentPasswordPrompt(
                    for: archiveURL,
                    action: .extract(archiveURL, entries: entries, chooseDestination: chooseDestination),
                    error: error,
                    in: appState
                )
            } catch {
                appState.activeConflictPrompt?.cancel()
                appState.activeConflictPrompt = nil
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.pendingExtractDestinationURL = nil
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Extraction failed: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    /// Directly extract an archive without opening a browser window, tracked in `TransferManager`.
    public func extractDirectly(
        archiveURL: URL,
        preferencesManager: PreferencesManager?,
        onNeedPasswordFallback: (@MainActor @Sendable (URL) -> Void)? = nil
    ) async {
        let prefs = preferencesManager?.loadPreferences() ?? AppPreferences()
        let destMode = ExtractDestinationMode(rawValue: prefs.extractDestinationMode) ?? .sameFolder
        let conflictPolicy = ExtractConflictPolicy(rawValue: prefs.extractConflictPolicy) ?? .ask
        let shouldUnwrap = prefs.unwrapSingleTopDirectory
        let shouldReveal = prefs.revealInFinderAfterExtract
        let shouldTrash = prefs.moveArchiveToTrashAfterExtract

        guard let destinationURL = resolveDirectExtractDestinationURL(
            archiveURL: archiveURL,
            destinationMode: destMode,
            customDirectoryPath: prefs.customExtractDirectory,
            conflictPolicy: conflictPolicy
        ) else {
            return
        }

        let destinationExistedBefore = Bento7zPathSafety.itemExists(at: destinationURL)
        let archiveBytes = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let localProgress = ProgressState()

        let context = startOperation(
            progressState: localProgress,
            description: String(localized: "Extracting \(archiveURL.lastPathComponent)…", bundle: .module),
            kind: .extract,
            totalBytes: archiveBytes,
            destinationURL: destinationURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: localProgress) {
            var stagingDir: URL?
            defer {
                if let stagingDir {
                    try? FileManager.default.removeItem(at: stagingDir)
                }
            }

            do {
                let stage = try Self.makeStagingDirectory(for: destinationURL)
                stagingDir = stage

                try await self.engine.extract(
                    archiveURL: archiveURL,
                    entries: nil,
                    to: stage,
                    password: nil,
                    encoding: nil,
                    onProgress: context.progressHandler
                )
                try Task.checkCancellation()

                if shouldUnwrap {
                    await Self.unwrapSingleTopDirectory(at: stage)
                }
                try Task.checkCancellation()

                let mergeResult = try await self.mergeStagedContents(
                    from: stage,
                    into: destinationURL,
                    initialPolicy: conflictPolicy,
                    appState: nil
                )
                try Task.checkCancellation()

                await self.completeOperation(context.id) {
                    preferencesManager?.recordArchive(archiveURL.path)
                }

                if shouldReveal && Bento7zPathSafety.itemExists(at: mergeResult.finalDestinationURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([mergeResult.finalDestinationURL])
                }

                if shouldTrash {
                    await Self.trashArchiveAndSplitVolumes(at: archiveURL)
                }
            } catch is CancellationError {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.abortOperation(context.id)
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.abortOperation(context.id)
                onNeedPasswordFallback?(archiveURL)
            } catch {
                if !destinationExistedBefore { try? FileManager.default.removeItem(at: destinationURL) }
                self.abortOperation(context.id)
                if !Self.isRunningTests, NSApp != nil {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = String(localized: "Extraction Failed", bundle: .module)
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Mutate, Test, Encoding & Open Entry

    public func addEntries(
        appState: AppState,
        urls: [URL],
        targetPrefix: String? = nil,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL,
              !urls.isEmpty else { return }

        let effectivePrefix: String?
        if let targetPrefix {
            effectivePrefix = targetPrefix.isEmpty ? nil : targetPrefix
        } else {
            let sub = appState.currentSubfolderPath
            effectivePrefix = sub.isEmpty ? nil : sub
        }

        let password = appState.archivePassword
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Adding to archive…", bundle: .module),
            kind: .addEntries,
            totalFiles: urls.count,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.addEntries(
                    to: archiveURL,
                    from: urls,
                    targetPrefix: effectivePrefix,
                    password: password,
                    onProgress: context.progressHandler
                )
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                try Task.checkCancellation()
                try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to add items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func removeEntries(
        appState: AppState,
        entries: [FileEntry],
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL,
              !entries.isEmpty else { return }

        let password = appState.archivePassword
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Removing items…", bundle: .module),
            kind: .removeEntries,
            totalFiles: entries.count,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.removeEntries(from: archiveURL, entries: entries, password: password)
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                try Task.checkCancellation()
                if !FileManager.default.fileExists(atPath: archiveURL.path) {
                    if appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL {
                        appState.reset()
                    }
                } else {
                    try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: password, into: appState)
                }
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to remove items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func renameEntry(
        appState: AppState,
        entry: FileEntry,
        newName: String,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.contains("\0"),
              trimmedName != ".",
              trimmedName != ".." else {
            appState.lastError = String(localized: "Invalid item name.", bundle: .module)
            return
        }

        let rawOldPath = Bento7zPathSafety.archiveRelativePath(for: entry)
        let oldPath: String
        do {
            oldPath = try Bento7zPathSafety.validatedRelativePath(rawOldPath)
        } catch {
            appState.lastError = error.localizedDescription
            return
        }

        var components = oldPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }
        components[components.count - 1] = trimmedName
        let newPath = components.joined(separator: "/")
        guard oldPath != newPath else { return }

        let password = appState.archivePassword
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Renaming…", bundle: .module),
            kind: .rename,
            totalFiles: 1,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.renameEntry(
                    in: archiveURL,
                    from: oldPath,
                    to: newPath,
                    password: password,
                    onProgress: context.progressHandler
                )
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                try Task.checkCancellation()
                try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to rename item: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func createFolder(
        appState: AppState,
        name: String,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.contains("\0"),
              trimmedName != ".",
              trimmedName != ".." else {
            appState.lastError = String(localized: "Invalid folder name.", bundle: .module)
            return
        }

        let subfolder = appState.currentSubfolderPath
        let fullPath = subfolder.isEmpty ? trimmedName : "\(subfolder)/\(trimmedName)"
        let password = appState.archivePassword

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Creating folder…", bundle: .module),
            kind: .createFolder,
            totalFiles: 1,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.createFolder(
                    in: archiveURL,
                    path: fullPath,
                    password: password,
                    onProgress: context.progressHandler
                )
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                try Task.checkCancellation()
                try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to create folder: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func testArchive(
        appState: AppState,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        appState.testArchiveResult = nil
        appState.lastError = nil
        let password = appState.archivePassword
        let archiveName = archiveURL.lastPathComponent

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Testing archive…", bundle: .module),
            kind: .test,
            totalBytes: appState.totalSize,
            totalFiles: appState.totalEntryCount > 0 ? appState.totalEntryCount : nil,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                let result = try await self.engine.testArchive(
                    at: archiveURL,
                    password: password,
                    onProgress: context.progressHandler
                )
                try Task.checkCancellation()
                await self.completeOperation(context.id) {
                    appState.testArchiveResult = TestArchiveResult(
                        archiveName: archiveName,
                        itemsCount: result.itemsCount,
                        passed: true
                    )
                }
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.testArchiveResult = TestArchiveResult(
                    archiveName: archiveName,
                    itemsCount: 0,
                    passed: false,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    public func reloadWithEncoding(
        _ encoding: FilenameEncodingOption,
        appState: AppState
    ) async {
        appState.selectedEncoding = encoding
        guard appState.mode == .browseArchive,
              let archiveURL = appState.sourceArchiveURL else { return }
        await browseArchive(
            at: archiveURL,
            password: appState.archivePassword,
            encoding: encoding,
            preserveSearch: true,
            appState: appState
        )
    }

    public func extractEntryForOpen(
        _ entry: FileEntry,
        archiveURL: URL?,
        password: String?,
        appURL: URL? = nil,
        appState: AppState? = nil
    ) async {
        if !entry.isFromArchive {
            await openLocalURL(entry.url, withApplicationAt: appURL)
            return
        }

        guard let effectiveArchiveURL = archiveURL ?? appState?.sourceArchiveURL else { return }
        let effectivePassword = password ?? appState?.archivePassword
        let encodingName = appState?.selectedEncoding.iconvName

        do {
            guard let extractedURL = try await DragDropManager.shared.prepareForDragThrowing(
                entry,
                sourceArchiveURL: effectiveArchiveURL,
                password: effectivePassword,
                encoding: encodingName
            ) else {
                return
            }

            if let appState {
                if let password {
                    appState.archivePassword = password
                }
                appState.cancelPasswordPrompt()
                appState.lastError = nil
            }
            await openLocalURL(extractedURL, withApplicationAt: appURL)
        } catch is CancellationError {
            return
        } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
            if let appState {
                if error == .wrongPassword && appState.sourceArchiveURL?.standardizedFileURL == effectiveArchiveURL.standardizedFileURL {
                    appState.archivePassword = nil
                }
                presentPasswordPrompt(
                    for: effectiveArchiveURL,
                    action: .openFile(entry, appURL: appURL),
                    error: error,
                    in: appState
                )
            }
        } catch {
            appState?.lastError = error.localizedDescription
        }
    }

    private func openLocalURL(_ fileURL: URL, withApplicationAt appURL: URL?) async {
        if let appURL {
            let config = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private static func trashArchiveAndSplitVolumes(at archiveURL: URL) async {
        DragDropManager.shared.invalidateCache(for: archiveURL)
        ArchiveCacheManager.shared.invalidate(for: archiveURL)
        await Task.detached(priority: .utility) {
            let volumes = Bento7zEngine.allSplitVolumeURLs(for: archiveURL)
            let targets = volumes.isEmpty ? [archiveURL] : volumes
            let fm = FileManager.default
            for url in targets where Bento7zPathSafety.itemExists(at: url) {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }
        }.value
    }
}
