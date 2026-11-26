import AppKit
import Darwin
import UniformTypeIdentifiers

extension CompressionCoordinator {

    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["SWIFT_TESTING_ENABLED"] != nil
    }

    func resolveCompressSaveURL(sourceURLs: [URL], settings: CompressionSettings) -> URL? {
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

    func resolveExtractDestinationURL(
        archiveURL: URL,
        chooseDestination: Bool,
        entries: [FileEntry]? = nil,
        conflictPolicy: ExtractConflictPolicy = .ask
    ) -> URL? {
        let baseDirectory: URL
        if chooseDestination {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Extract Here", bundle: .module)
            let response = panel.runModal()
            guard response == .OK, let chosenDir = panel.url else { return nil }
            baseDirectory = chosenDir
        } else {
            baseDirectory = archiveURL.deletingLastPathComponent()
        }

        if let entries, !entries.isEmpty {
            return baseDirectory
        }

        let folderName = PathUtils.splitArchiveName(archiveURL.lastPathComponent).stem
        let safeFolderName = folderName.isEmpty ? "Extracted" : folderName
        let proposed = baseDirectory.appendingPathComponent(safeFolderName)

        switch conflictPolicy {
        case .overwrite, .skip:
            return proposed
        case .rename, .ask:
            return PathUtils.uniqueFileURL(for: proposed)
        }
    }

    func resolveDirectExtractDestinationURL(
        archiveURL: URL,
        destinationMode: ExtractDestinationMode,
        customDirectoryPath: String?,
        conflictPolicy: ExtractConflictPolicy,
        overrideBaseDirectory: URL? = nil
    ) -> URL? {
        let fm = FileManager.default
        let baseDirectory: URL
        if let overrideBaseDirectory {
            baseDirectory = overrideBaseDirectory
        } else {
            switch destinationMode {
            case .sameFolder:
                baseDirectory = archiveURL.deletingLastPathComponent()
            case .customFolder:
                if let customDirectoryPath, !customDirectoryPath.isEmpty {
                    let candidate = URL(fileURLWithPath: customDirectoryPath, isDirectory: true)
                    do {
                        try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                        baseDirectory = candidate
                    } catch {
                        baseDirectory = archiveURL.deletingLastPathComponent()
                    }
                } else {
                    baseDirectory = archiveURL.deletingLastPathComponent()
                }
            case .askEveryTime:
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = String(localized: "Extract Here", bundle: .module)
                let response = panel.runModal()
                guard response == .OK, let chosenDir = panel.url else { return nil }
                baseDirectory = chosenDir
            }
        }

        let folderName = PathUtils.splitArchiveName(archiveURL.lastPathComponent).stem
        let safeFolderName = folderName.isEmpty ? "Extracted" : folderName
        let proposed = baseDirectory.appendingPathComponent(safeFolderName)

        switch conflictPolicy {
        case .overwrite, .skip:
            return proposed
        case .rename, .ask:
            return PathUtils.uniqueFileURL(for: proposed)
        }
    }

    nonisolated static func makeStagingDirectory(for destinationURL: URL) throws -> URL {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        let stagingName = ".bentozip_stage_\(UUID().uuidString)"
        let stagingParent: URL
        if Bento7zPathSafety.itemStatus(at: parentDir).isDirectory, fm.isWritableFile(atPath: parentDir.path) {
            stagingParent = parentDir
        } else if Bento7zPathSafety.itemStatus(at: destinationURL).isDirectory, fm.isWritableFile(atPath: destinationURL.path) {
            stagingParent = destinationURL
        } else {
            stagingParent = fm.temporaryDirectory
        }
        let stagingURL = stagingParent.appendingPathComponent(stagingName, isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        return stagingURL
    }

    func mergeStagedContents(
        from stagingDir: URL,
        into destinationURL: URL,
        initialPolicy: ExtractConflictPolicy,
        appState: AppState?
    ) async throws -> (finalDestinationURL: URL, mergedTopLevelURLs: [URL]) {
        let fm = FileManager.default

        var activePolicy = initialPolicy
        var mergedTopLevelURLs: [URL] = []

        func itemStatus(at url: URL) -> (exists: Bool, isDirectory: Bool) {
            let status = Bento7zPathSafety.itemStatus(at: url)
            return (status.exists, status.isDirectory)
        }

        func atomicReplaceItem(at destItem: URL, with srcItem: URL, isSourceDir: Bool, isDestDir: Bool, parentDir: URL) throws {
            if !isSourceDir && !isDestDir {
                let backupName = ".bentozip_bak_\(UUID().uuidString)_\(destItem.lastPathComponent)"
                if (try? fm.replaceItemAt(destItem, withItemAt: srcItem, backupItemName: backupName, options: [])) != nil {
                    return
                }
            }
            let backupURL = parentDir.appendingPathComponent(".bentozip_bak_\(UUID().uuidString)")
            try fm.moveItem(at: destItem, to: backupURL)
            do {
                try fm.moveItem(at: srcItem, to: destItem)
                try? fm.removeItem(at: backupURL)
            } catch {
                if !itemStatus(at: destItem).exists {
                    try? fm.moveItem(at: backupURL, to: destItem)
                }
                throw error
            }
        }

        func resolveConflict(
            sourceName: String,
            destItem: URL,
            isDirectory: Bool
        ) async throws -> ExtractConflictResolution {
            switch activePolicy {
            case .overwrite:
                return .overwrite
            case .skip:
                return .skip
            case .rename:
                return .rename
            case .ask:
                if let appState {
                    guard let choice = await promptForConflictInAppState(
                        appState: appState,
                        sourceName: sourceName,
                        destinationURL: destItem,
                        isDirectory: isDirectory
                    ) else {
                        throw CancellationError()
                    }
                    if choice.applyToAll {
                        switch choice.resolution {
                        case .overwrite: activePolicy = .overwrite
                        case .skip: activePolicy = .skip
                        case .rename: activePolicy = .rename
                        }
                    }
                    return choice.resolution
                } else if !Self.isRunningTests, NSApp != nil {
                    let choice = promptForConflictWithAlert(
                        sourceName: sourceName,
                        destinationURL: destItem,
                        isDirectory: isDirectory
                    )
                    if choice.applyToAll {
                        switch choice.resolution {
                        case .overwrite: activePolicy = .overwrite
                        case .skip: activePolicy = .skip
                        case .rename: activePolicy = .rename
                        }
                    }
                    return choice.resolution
                } else {
                    return .rename
                }
            }
        }

        func mergeDirectory(from sourceDir: URL, into targetDir: URL, isTopLevel: Bool) async throws {
            let children = try fm.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: nil,
                options: []
            )
            for srcItem in children {
                try Task.checkCancellation()
                let name = srcItem.lastPathComponent
                let destItem = targetDir.appendingPathComponent(name)
                let srcStat = itemStatus(at: srcItem)
                let destStat = itemStatus(at: destItem)

                if !destStat.exists {
                    try fm.moveItem(at: srcItem, to: destItem)
                    if isTopLevel { mergedTopLevelURLs.append(destItem) }
                    continue
                }

                if srcStat.isDirectory && destStat.isDirectory {
                    try await mergeDirectory(from: srcItem, into: destItem, isTopLevel: false)
                    try? fm.removeItem(at: srcItem)
                    if isTopLevel { mergedTopLevelURLs.append(destItem) }
                    continue
                }

                let resolution = try await resolveConflict(
                    sourceName: name,
                    destItem: destItem,
                    isDirectory: srcStat.isDirectory
                )
                try Task.checkCancellation()

                switch resolution {
                case .overwrite:
                    try atomicReplaceItem(
                        at: destItem,
                        with: srcItem,
                        isSourceDir: srcStat.isDirectory,
                        isDestDir: destStat.isDirectory,
                        parentDir: targetDir
                    )
                    if isTopLevel { mergedTopLevelURLs.append(destItem) }
                case .skip:
                    try? fm.removeItem(at: srcItem)
                case .rename:
                    let uniqueURL = PathUtils.uniqueFileURL(for: destItem)
                    try fm.moveItem(at: srcItem, to: uniqueURL)
                    if isTopLevel { mergedTopLevelURLs.append(uniqueURL) }
                }
            }
        }

        var effectiveDestinationURL = destinationURL
        var backupNonDirectoryURL: URL?

        let rootDestStat = itemStatus(at: destinationURL)
        if rootDestStat.exists && !rootDestStat.isDirectory {
            let resolution = try await resolveConflict(
                sourceName: destinationURL.lastPathComponent,
                destItem: destinationURL,
                isDirectory: true
            )
            try Task.checkCancellation()

            switch resolution {
            case .skip:
                return (destinationURL, [])
            case .rename:
                effectiveDestinationURL = PathUtils.uniqueFileURL(for: destinationURL)
            case .overwrite:
                let backup = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".bentozip_bak_\(UUID().uuidString)")
                try fm.moveItem(at: destinationURL, to: backup)
                backupNonDirectoryURL = backup
            }
        }

        do {
            try fm.createDirectory(at: effectiveDestinationURL, withIntermediateDirectories: true)
            try await mergeDirectory(from: stagingDir, into: effectiveDestinationURL, isTopLevel: true)
            if let backupNonDirectoryURL {
                try? fm.removeItem(at: backupNonDirectoryURL)
            }
            return (effectiveDestinationURL, mergedTopLevelURLs)
        } catch {
            if let backupNonDirectoryURL {
                try? fm.removeItem(at: effectiveDestinationURL)
                try? fm.moveItem(at: backupNonDirectoryURL, to: effectiveDestinationURL)
            }
            throw error
        }
    }

    private func promptForConflictInAppState(
        appState: AppState,
        sourceName: String,
        destinationURL: URL,
        isDirectory: Bool
    ) async -> (resolution: ExtractConflictResolution, applyToAll: Bool)? {
        final class ResumeBox: @unchecked Sendable {
            var continuation: CheckedContinuation<(resolution: ExtractConflictResolution, applyToAll: Bool)?, Never>?
            var resolved = false
        }
        let box = ResumeBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.continuation = continuation
                let prompt = ExtractConflictPrompt(
                    sourceName: sourceName,
                    destinationURL: destinationURL,
                    isDirectory: isDirectory
                ) { [weak appState] resolution, applyToAll in
                    guard !box.resolved else { return }
                    box.resolved = true
                    appState?.activeConflictPrompt = nil
                    if let resolution {
                        box.continuation?.resume(returning: (resolution, applyToAll))
                    } else {
                        box.continuation?.resume(returning: nil)
                    }
                    box.continuation = nil
                }
                appState.activeConflictPrompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak appState] in
                guard !box.resolved else { return }
                box.resolved = true
                appState?.activeConflictPrompt = nil
                box.continuation?.resume(returning: nil)
                box.continuation = nil
            }
        }
    }

    private func promptForConflictWithAlert(
        sourceName: String,
        destinationURL: URL,
        isDirectory: Bool
    ) -> (resolution: ExtractConflictResolution, applyToAll: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "An item named \"\(sourceName)\" already exists in \"\(destinationURL.deletingLastPathComponent().lastPathComponent)\".",
            bundle: .module
        )
        alert.informativeText = isDirectory
            ? String(localized: "Do you want to replace the existing folder, keep both, or skip it?", bundle: .module)
            : String(localized: "Do you want to replace the existing file, keep both, or skip it?", bundle: .module)
        alert.addButton(withTitle: String(localized: "Keep Both", bundle: .module))
        alert.addButton(withTitle: String(localized: "Replace", bundle: .module))
        alert.addButton(withTitle: String(localized: "Skip", bundle: .module))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Apply to all", bundle: .module)

        let response = alert.runModal()
        let applyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            return (.rename, applyToAll)
        case .alertSecondButtonReturn:
            return (.overwrite, applyToAll)
        default:
            return (.skip, applyToAll)
        }
    }

    nonisolated static func unwrapSingleTopDirectory(at url: URL) async {
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
