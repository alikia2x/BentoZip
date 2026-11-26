import AppKit
import Darwin

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

        if settings.compressEachSeparately && sourceURLs.count > 1 {
            await compressEachSeparately(
                sourceURLs: sourceURLs,
                settings: settings,
                shouldReveal: shouldReveal,
                preferencesManager: preferencesManager,
                appState: appState,
                progressState: progressState
            )
            return
        }

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

    private func compressEachSeparately(
        sourceURLs: [URL],
        settings: CompressionSettings,
        shouldReveal: Bool,
        preferencesManager: PreferencesManager?,
        appState: AppState,
        progressState: ProgressState
    ) async {
        let totalCount = sourceURLs.count
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Compressing \(totalCount) items…", bundle: .module),
            kind: .compress,
            totalBytes: appState.totalSize,
            totalFiles: totalCount,
            destinationURL: sourceURLs.first?.deletingLastPathComponent()
        )

        await runManagedTask(context: context, progressState: progressState) {
            var createdURLs: [URL] = []
            createdURLs.reserveCapacity(totalCount)
            var currentSaveURL: URL?

            do {
                for (index, sourceURL) in sourceURLs.enumerated() {
                    try Task.checkCancellation()

                    let stem = AppState.defaultArchiveStem(for: [sourceURL])
                    let fileName = "\(stem).\(settings.format.fileExtension)"
                    let proposedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(fileName)
                    let itemSaveURL = PathUtils.uniqueFileURL(for: proposedURL)
                    currentSaveURL = itemSaveURL

                    var itemSettings = settings
                    itemSettings.archiveName = itemSaveURL.lastPathComponent

                    let baseFraction = Double(index) / Double(totalCount)
                    let spanFraction = 1.0 / Double(totalCount)
                    let itemLabel = sourceURL.lastPathComponent
                    let parentHandler = context.progressHandler

                    let itemProgressHandler: @Sendable (ArchiveProgress) -> Void = { update in
                        let clamped = min(max(update.fractionCompleted, 0.0), 1.0)
                        let scaled = ArchiveProgress(
                            fractionCompleted: baseFraction + clamped * spanFraction,
                            currentFile: update.currentFile ?? itemLabel,
                            processedBytes: update.processedBytes,
                            totalBytes: update.totalBytes,
                            isFileEvent: update.isFileEvent,
                            fileCountDelta: update.fileCountDelta,
                            stage: update.stage
                        )
                        parentHandler(scaled)
                    }

                    try await self.engine.create(
                        from: [sourceURL],
                        to: itemSaveURL,
                        settings: itemSettings,
                        onProgress: itemProgressHandler
                    )
                    try Task.checkCancellation()

                    let splitVolumes = (settings.volumeSizeBytes > 0)
                        ? Bento7zEngine.splitVolumeURLs(for: itemSaveURL)
                        : []
                    let primaryURL = splitVolumes.first ?? itemSaveURL
                    currentSaveURL = nil

                    createdURLs.append(primaryURL)
                    preferencesManager?.recordArchive(primaryURL.path)
                }

                await self.completeOperation(context.id, finalOutputURL: createdURLs.last) {
                    appState.lastError = nil
                }

                if shouldReveal && !createdURLs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(createdURLs)
                }
            } catch is CancellationError {
                if let partial = currentSaveURL {
                    try? FileManager.default.removeItem(at: partial)
                    if settings.volumeSizeBytes > 0 {
                        Bento7zEngine.cleanupSplitVolumes(baseArchiveURL: partial)
                    }
                }
                self.abortOperation(context.id)
            } catch {
                if let partial = currentSaveURL {
                    try? FileManager.default.removeItem(at: partial)
                    if settings.volumeSizeBytes > 0 {
                        Bento7zEngine.cleanupSplitVolumes(baseArchiveURL: partial)
                    }
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
        let autoTryVault = (password == nil)
            && (appState.preferencesManager?.loadPreferences().autoTryVaultPasswords ?? appState.autoTryVaultPasswords)
        let encodingName = appState.selectedEncoding.iconvName
        let shouldUnwrap = appState.unwrapSingleTopDirectory
        let shouldReveal = appState.revealInFinderAfterExtract
        let shouldTrashAfterExtract = isFullExtract && appState.moveArchiveToTrashAfterExtract
        let shouldCloseAfterExtract = isFullExtract && appState.closeWindowAfterExtract
        let shouldStripQuarantine = appState.stripQuarantineOnExtract
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
                var stage = try Self.makeStagingDirectory(for: destinationURL)
                stagingDir = stage

                var matchedVaultPassword: String?
                do {
                    try await self.engine.extract(
                        archiveURL: archiveURL,
                        entries: entries,
                        to: stage,
                        password: password,
                        encoding: encodingName,
                        onProgress: context.progressHandler
                    )
                } catch let error as Bento7zError where error == .passwordRequired && autoTryVault {
                    var succeeded = false
                    for candidate in self.passwordVault.allPasswords() {
                        try Task.checkCancellation()
                        try? FileManager.default.removeItem(at: stage)
                        stage = try Self.makeStagingDirectory(for: destinationURL)
                        stagingDir = stage
                        do {
                            try await self.engine.extract(
                                archiveURL: archiveURL,
                                entries: entries,
                                to: stage,
                                password: candidate,
                                encoding: encodingName,
                                onProgress: context.progressHandler
                            )
                            matchedVaultPassword = candidate
                            succeeded = true
                            break
                        } catch let attemptError as Bento7zError
                            where attemptError == .passwordRequired || attemptError == .wrongPassword {
                            continue
                        }
                    }
                    if !succeeded {
                        throw error
                    }
                }
                try Task.checkCancellation()

                if let matchedVaultPassword,
                   appState.sourceArchiveURL?.standardizedFileURL == archiveURL.standardizedFileURL {
                    appState.archivePassword = matchedVaultPassword
                }

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

                if shouldStripQuarantine {
                    let stripTargets: [URL] = if !isFullExtract, !mergedURLs.isEmpty {
                        mergedURLs
                    } else if isFullExtract && (!mergedURLs.isEmpty || Bento7zPathSafety.itemExists(at: finalDestinationURL)) {
                        [finalDestinationURL]
                    } else {
                        []
                    }
                    if !stripTargets.isEmpty {
                        await Self.stripQuarantineAttributes(at: stripTargets)
                    }
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
        _ = await extractSingleDirectly(
            archiveURL: archiveURL,
            preferencesManager: preferencesManager,
            overrideBaseDirectory: nil,
            revealImmediately: true,
            onNeedPasswordFallback: onNeedPasswordFallback
        )
    }

    /// Directly extract multiple archives in sequence, revealing all extracted outputs together when configured.
    public func extractMultipleDirectly(
        archiveURLs: [URL],
        preferencesManager: PreferencesManager?,
        onNeedPasswordFallback: (@MainActor @Sendable (URL) -> Void)? = nil
    ) async {
        guard !archiveURLs.isEmpty else { return }
        if archiveURLs.count == 1 {
            await extractDirectly(
                archiveURL: archiveURLs[0],
                preferencesManager: preferencesManager,
                onNeedPasswordFallback: onNeedPasswordFallback
            )
            return
        }

        let prefs = preferencesManager?.loadPreferences() ?? AppPreferences()
        let destMode = ExtractDestinationMode(rawValue: prefs.extractDestinationMode) ?? .sameFolder
        let shouldReveal = prefs.revealInFinderAfterExtract

        var overrideBaseDirectory: URL?
        if destMode == .askEveryTime {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Extract Here", bundle: .module)
            let response = panel.runModal()
            guard response == .OK, let chosenDir = panel.url else { return }
            overrideBaseDirectory = chosenDir
        }

        var extractedURLs: [URL] = []
        extractedURLs.reserveCapacity(archiveURLs.count)

        for archiveURL in archiveURLs {
            if Task.isCancelled { break }
            if let extracted = await extractSingleDirectly(
                archiveURL: archiveURL,
                preferencesManager: preferencesManager,
                overrideBaseDirectory: overrideBaseDirectory,
                revealImmediately: false,
                onNeedPasswordFallback: onNeedPasswordFallback
            ) {
                extractedURLs.append(extracted)
            }
        }

        if shouldReveal && !extractedURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(extractedURLs)
        }
    }

    private func extractSingleDirectly(
        archiveURL: URL,
        preferencesManager: PreferencesManager?,
        overrideBaseDirectory: URL?,
        revealImmediately: Bool,
        onNeedPasswordFallback: (@MainActor @Sendable (URL) -> Void)?
    ) async -> URL? {
        let prefs = preferencesManager?.loadPreferences() ?? AppPreferences()
        let destMode = ExtractDestinationMode(rawValue: prefs.extractDestinationMode) ?? .sameFolder
        let conflictPolicy = ExtractConflictPolicy(rawValue: prefs.extractConflictPolicy) ?? .ask
        let shouldUnwrap = prefs.unwrapSingleTopDirectory
        let shouldReveal = prefs.revealInFinderAfterExtract && revealImmediately
        let shouldTrash = prefs.moveArchiveToTrashAfterExtract
        let shouldStripQuarantine = prefs.stripQuarantineOnExtract
        let autoTryVault = prefs.autoTryVaultPasswords

        guard let destinationURL = resolveDirectExtractDestinationURL(
            archiveURL: archiveURL,
            destinationMode: destMode,
            customDirectoryPath: prefs.customExtractDirectory,
            conflictPolicy: conflictPolicy,
            overrideBaseDirectory: overrideBaseDirectory
        ) else {
            return nil
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

        var extractedOutputURL: URL?

        await runManagedTask(context: context, progressState: localProgress) {
            var stagingDir: URL?
            defer {
                if let stagingDir {
                    try? FileManager.default.removeItem(at: stagingDir)
                }
            }

            do {
                var stage = try Self.makeStagingDirectory(for: destinationURL)
                stagingDir = stage

                do {
                    try await self.engine.extract(
                        archiveURL: archiveURL,
                        entries: nil,
                        to: stage,
                        password: nil,
                        encoding: nil,
                        onProgress: context.progressHandler
                    )
                } catch let error as Bento7zError where error == .passwordRequired && autoTryVault {
                    var succeeded = false
                    for candidate in self.passwordVault.allPasswords() {
                        try Task.checkCancellation()
                        try? FileManager.default.removeItem(at: stage)
                        stage = try Self.makeStagingDirectory(for: destinationURL)
                        stagingDir = stage
                        do {
                            try await self.engine.extract(
                                archiveURL: archiveURL,
                                entries: nil,
                                to: stage,
                                password: candidate,
                                encoding: nil,
                                onProgress: context.progressHandler
                            )
                            succeeded = true
                            break
                        } catch let attemptError as Bento7zError
                            where attemptError == .passwordRequired || attemptError == .wrongPassword {
                            continue
                        }
                    }
                    if !succeeded {
                        throw error
                    }
                }
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

                if Bento7zPathSafety.itemExists(at: mergeResult.finalDestinationURL) {
                    extractedOutputURL = mergeResult.finalDestinationURL
                }

                await self.completeOperation(context.id) {
                    preferencesManager?.recordArchive(archiveURL.path)
                }

                if shouldStripQuarantine && Bento7zPathSafety.itemExists(at: mergeResult.finalDestinationURL) {
                    await Self.stripQuarantineAttributes(at: [mergeResult.finalDestinationURL])
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

        return extractedOutputURL
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
            preserveNestedStack: appState.isViewingNestedArchive,
            appState: appState
        )
    }

    public func moveEntries(
        appState: AppState,
        entries: [FileEntry],
        toTargetDir targetDir: String,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              !appState.isViewingNestedArchive,
              let archiveURL = appState.sourceArchiveURL,
              !entries.isEmpty else { return }

        let password = appState.archivePassword
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Moving items…", bundle: .module),
            kind: .moveEntries,
            totalFiles: entries.count,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.moveEntries(
                    in: archiveURL,
                    entries: entries,
                    toTargetDir: targetDir,
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
                appState.lastError = String(localized: "Failed to move items: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    public func updatePassword(
        appState: AppState,
        newPassword: String?,
        encryptionMethod: ZipEncryptionMethod = .aes256,
        encryptHeaders: Bool = true,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              !appState.isViewingNestedArchive,
              let archiveURL = appState.sourceArchiveURL else { return }

        let oldPassword = appState.archivePassword
        let normalizedNewPassword = (newPassword?.isEmpty == false) ? newPassword : nil
        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Updating archive password…", bundle: .module),
            kind: .updatePassword,
            totalBytes: appState.totalSize,
            destinationURL: archiveURL,
            sourceArchiveURL: archiveURL
        )

        await runManagedTask(context: context, progressState: progressState) {
            do {
                try await self.engine.updatePassword(
                    in: archiveURL,
                    oldPassword: oldPassword,
                    newPassword: normalizedNewPassword,
                    encryptionMethod: encryptionMethod.bento7zValue,
                    encryptHeaders: encryptHeaders,
                    onProgress: context.progressHandler
                )
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                appState.archivePassword = normalizedNewPassword
                try Task.checkCancellation()
                try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: normalizedNewPassword, into: appState)
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to update password: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    /// Extract a nested archive entry into a temporary directory, push the parent archive onto `nestedArchiveStack`, and browse it.
    public func openNestedArchive(
        entry: FileEntry,
        appState: AppState,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              !entry.isDirectory,
              entry.isFromArchive,
              let parentArchiveURL = appState.sourceArchiveURL else { return }

        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.contains("\\"),
              !trimmedName.contains("\0"),
              trimmedName != ".",
              trimmedName != ".." else {
            appState.lastError = String(localized: "Invalid archive entry name.", bundle: .module)
            return
        }

        let parentPassword = appState.archivePassword
        let encodingName = appState.selectedEncoding.iconvName
        let relPath = Bento7zPathSafety.archiveRelativePath(for: entry)
        let pid = ProcessInfo.processInfo.processIdentifier
        let nestedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoZip-nested-\(pid)-\(UUID().uuidString)", isDirectory: true)
        let nestedArchiveURL = nestedDir.appendingPathComponent(trimmedName)

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Opening \(trimmedName)…", bundle: .module),
            kind: .extract,
            totalBytes: max(0, entry.size),
            totalFiles: 1,
            destinationURL: nestedArchiveURL,
            sourceArchiveURL: parentArchiveURL
        )

        var didOpenNested = false
        await runManagedTask(context: context, progressState: progressState) {
            do {
                try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
                if let b7z = self.engine as? Bento7zEngine {
                    try await b7z.extractEntry(
                        from: parentArchiveURL,
                        entryPath: relPath,
                        to: nestedArchiveURL,
                        password: parentPassword,
                        encoding: encodingName,
                        onProgress: context.progressHandler
                    )
                } else {
                    try await self.engine.extract(
                        archiveURL: parentArchiveURL,
                        entries: [entry],
                        to: nestedDir,
                        password: parentPassword,
                        encoding: encodingName,
                        onProgress: context.progressHandler
                    )
                    let directCandidate = try Bento7zPathSafety.verifiedDescendantURL(relativePath: relPath, baseDirectory: nestedDir)
                    if directCandidate.standardizedFileURL != nestedArchiveURL.standardizedFileURL,
                       Bento7zPathSafety.itemExists(at: directCandidate) {
                        if Bento7zPathSafety.itemExists(at: nestedArchiveURL) {
                            try FileManager.default.removeItem(at: nestedArchiveURL)
                        }
                        try FileManager.default.moveItem(at: directCandidate, to: nestedArchiveURL)
                    }
                }
                try Task.checkCancellation()
                guard Bento7zPathSafety.itemExists(at: nestedArchiveURL) else {
                    throw Bento7zError.fileNotFound(relPath)
                }

                await self.completeOperation(context.id) {
                    appState.lastError = nil
                }
                didOpenNested = true
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: nestedDir)
                self.abortOperation(context.id)
            } catch let error as Bento7zError where error == .passwordRequired || error == .wrongPassword {
                try? FileManager.default.removeItem(at: nestedDir)
                if error == .wrongPassword && appState.sourceArchiveURL?.standardizedFileURL == parentArchiveURL.standardizedFileURL {
                    appState.archivePassword = nil
                }
                self.abortOperation(context.id)
                self.presentPasswordPrompt(
                    for: parentArchiveURL,
                    action: .openNestedArchive(entry),
                    error: error,
                    in: appState
                )
            } catch {
                try? FileManager.default.removeItem(at: nestedDir)
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Unable to open nested archive: \(error.localizedDescription)", bundle: .module)
            }
        }

        if didOpenNested {
            appState.pushNestedArchiveFrame(newTempDirectoryURL: nestedDir)
            await browseArchive(
                at: nestedArchiveURL,
                password: nil,
                encoding: .auto,
                preserveNestedStack: true,
                appState: appState
            )
        }
    }

    /// Save an externally modified temporary file back into its parent writable archive at its original path.
    public func saveBackExternalEdit(
        _ edit: PendingExternalEdit,
        appState: AppState,
        progressState: ProgressState
    ) async {
        guard !progressState.isOperationInProgress,
              appState.mode == .browseArchive,
              appState.isWritableArchive,
              appState.sourceArchiveURL?.standardizedFileURL == edit.archiveURL.standardizedFileURL else { return }

        guard Bento7zPathSafety.itemExists(at: edit.tempURL) else {
            appState.pendingExternalEdits.removeAll { $0.id == edit.id }
            appState.lastError = String(localized: "Modified temporary file could not be found.", bundle: .module)
            return
        }

        let cleanRelPath: String
        do {
            cleanRelPath = try Bento7zPathSafety.validatedRelativePath(edit.archiveRelativePath)
        } catch {
            appState.lastError = error.localizedDescription
            return
        }

        let components = cleanRelPath.split(separator: "/").map(String.init)
        let leafName = components.last ?? edit.fileName
        let parentPrefix: String? = components.count > 1 ? components.dropLast().joined(separator: "/") : nil
        let password = appState.archivePassword
        let archiveURL = edit.archiveURL

        let context = startOperation(
            progressState: progressState,
            description: String(localized: "Saving \(leafName) to archive…", bundle: .module),
            kind: .addEntries,
            totalFiles: 1,
            destinationURL: archiveURL,
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
                let sourceURLToAdd: URL
                if edit.tempURL.lastPathComponent == leafName {
                    sourceURLToAdd = edit.tempURL
                } else {
                    let tempStage = FileManager.default.temporaryDirectory
                        .appendingPathComponent("BentoZip_saveback_\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tempStage, withIntermediateDirectories: true)
                    stagingDir = tempStage
                    let renamed = tempStage.appendingPathComponent(leafName)
                    try FileManager.default.copyItem(at: edit.tempURL, to: renamed)
                    sourceURLToAdd = renamed
                }

                try await self.engine.addEntries(
                    to: archiveURL,
                    from: [sourceURLToAdd],
                    targetPrefix: parentPrefix,
                    password: password,
                    onProgress: context.progressHandler
                )
                DragDropManager.shared.invalidateCache(for: archiveURL)
                ArchiveCacheManager.shared.invalidate(for: archiveURL)
                appState.externalEditMonitor.acknowledgeChange(at: edit.tempURL)
                appState.pendingExternalEdits.removeAll { $0.id == edit.id }
                try Task.checkCancellation()
                try await self.refreshArchiveContentsIfStillViewing(at: archiveURL, password: password, into: appState)
                appState.lastError = nil
                await self.completeOperation(context.id)
            } catch is CancellationError {
                self.abortOperation(context.id)
            } catch {
                self.abortOperation(context.id)
                appState.lastError = String(localized: "Failed to save modified file back to archive: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    /// Compute SHA-256 and MD5 checksums for a local or archive file entry.
    public func computeChecksums(
        for entry: FileEntry,
        appState: AppState
    ) async throws -> FileChecksums {
        guard !entry.isDirectory else {
            throw Bento7zError.operationFailed(
                String(localized: "Checksums can only be computed for files.", bundle: .module),
                "INVALID_PARAMS"
            )
        }
        if !entry.isFromArchive {
            return try await FileHashUtils.computeHashes(for: entry.url)
        }
        guard let archiveURL = appState.sourceArchiveURL else {
            throw Bento7zError.fileNotFound(entry.name)
        }
        guard let extractedURL = try await DragDropManager.shared.prepareForDragThrowing(
            entry,
            sourceArchiveURL: archiveURL,
            password: appState.archivePassword,
            encoding: appState.selectedEncoding.iconvName
        ) else {
            throw Bento7zError.fileNotFound(entry.name)
        }
        return try await FileHashUtils.computeHashes(for: extractedURL)
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

                if appState.isWritableArchive,
                   appState.sourceArchiveURL?.standardizedFileURL == effectiveArchiveURL.standardizedFileURL {
                    appState.externalEditMonitor.watch(
                        tempURL: extractedURL,
                        archiveURL: effectiveArchiveURL,
                        archiveRelativePath: Bento7zPathSafety.archiveRelativePath(for: entry),
                        password: appState.archivePassword
                    )
                }
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

    private static func stripQuarantineAttributes(at urls: [URL]) async {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let attrName = "com.apple.quarantine"
            for rootURL in urls {
                _ = removexattr(rootURL.path, attrName, XATTR_NOFOLLOW)
                if Bento7zPathSafety.itemStatus(at: rootURL).isDirectory,
                   let enumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: nil,
                    options: []
                   ) {
                    while let child = enumerator.nextObject() as? URL {
                        _ = removexattr(child.path, attrName, XATTR_NOFOLLOW)
                    }
                }
            }
        }.value
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
