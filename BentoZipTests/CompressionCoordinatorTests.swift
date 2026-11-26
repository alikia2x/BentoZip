import Darwin
import Foundation
import Testing
@testable import BentoZipCore

@Suite(.serialized) @MainActor
struct CompressionCoordinatorTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("CoordinatorTest_\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Mock Engine for Deterministic Coordinator Tests

    private final class MockArchiveEngine: ArchiveEngine, @unchecked Sendable {
        var listResult: Result<[FileEntry], Error> = .success([])
        var listHandler: ((URL, String?) async throws -> [FileEntry])?
        var extractHandler: ((URL, [FileEntry]?, URL, String?, @Sendable (ArchiveProgress) -> Void) async throws -> Void)?
        var createHandler: (([URL], URL, CompressionSettings, @escaping @Sendable (ArchiveProgress) -> Void) async throws -> Void)?
        var addHandler: ((URL, [URL], String?, @Sendable (ArchiveProgress) -> Void) async throws -> Void)?
        var removeHandler: ((URL, [FileEntry], String?) async throws -> Void)?

        func listEntries(in archiveURL: URL, password: String?) async throws -> [FileEntry] {
            if let listHandler {
                return try await listHandler(archiveURL, password)
            }
            return try listResult.get()
        }

        func extract(
            archiveURL: URL,
            entries: [FileEntry]?,
            to destinationURL: URL,
            password: String?,
            onProgress: @escaping @Sendable (ArchiveProgress) -> Void
        ) async throws {
            if let extractHandler {
                try await extractHandler(archiveURL, entries, destinationURL, password, onProgress)
            }
        }

        func create(
            from sourceURLs: [URL],
            to archiveURL: URL,
            settings: CompressionSettings,
            onProgress: @escaping @Sendable (ArchiveProgress) -> Void
        ) async throws {
            if let createHandler {
                try await createHandler(sourceURLs, archiveURL, settings, onProgress)
            }
        }

        func removeEntries(from archiveURL: URL, entries: [FileEntry], password: String?) async throws {
            if let removeHandler {
                try await removeHandler(archiveURL, entries, password)
            }
        }

        func addEntries(
            to archiveURL: URL,
            from sourceURLs: [URL],
            password: String?,
            onProgress: @escaping @Sendable (ArchiveProgress) -> Void
        ) async throws {
            if let addHandler {
                try await addHandler(archiveURL, sourceURLs, password, onProgress)
            }
        }
    }

    // MARK: - browseArchive & Password Flow

    @Test func browseArchive_realZip_populatesAppState() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("data.txt")
        try "test content".write(to: fileURL, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("browse.zip")
        try await engine.create(from: [fileURL], to: archiveURL, settings: CompressionSettings()) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        #expect(appState.mode == .browseArchive)
        #expect(appState.sourceArchiveURL == archiveURL)
        #expect(!appState.fileEntries.isEmpty)
        #expect(appState.archiveFormatName == "ZIP")
    }

    @Test func browseArchive_nonexistent_setsError() async {
        let coordinator = CompressionCoordinator()
        let appState = AppState()
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_browse_xyz_999.zip")

        await coordinator.browseArchive(at: nonexistent, appState: appState)
        #expect(appState.lastError != nil)
        #expect(appState.mode == .empty)
    }

    @Test func browseArchive_encrypted_triggersPasswordPromptAndSubmitUnlocks() async throws {
        let mock = MockArchiveEngine()
        mock.listHandler = { _, password in
            if password == nil {
                throw Bento7zError.passwordRequired
            }
            if password != "secret" {
                throw Bento7zError.wrongPassword
            }
            return [
                FileEntry(
                    url: URL(fileURLWithPath: "/archive-root/secret.txt"),
                    name: "secret.txt",
                    size: 100,
                    isEncrypted: true,
                    isFromArchive: true,
                    archiveRelativePath: "secret.txt"
                )
            ]
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        let archiveURL = URL(fileURLWithPath: "/tmp/locked.7z")

        await coordinator.browseArchive(at: archiveURL, appState: appState)
        #expect(appState.needsPasswordPrompt)
        #expect(appState.pendingPasswordArchiveURL == archiveURL)
        #expect(appState.lastError == nil)

        await coordinator.submitPassword("wrong", appState: appState)
        #expect(appState.needsPasswordPrompt)
        #expect(appState.passwordPromptReason == Bento7zError.wrongPassword.localizedDescription)

        await coordinator.submitPassword("secret", appState: appState)
        #expect(!appState.needsPasswordPrompt)
        #expect(appState.mode == .browseArchive)
        #expect(appState.archivePassword == "secret")
        #expect(appState.isArchiveEncrypted)
        #expect(appState.fileEntries.count == 1)
    }

    // MARK: - Compress & Progress

    @Test func compress_resetsProgressStateAndUpdatesCurrentFileName() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("hello.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let mock = MockArchiveEngine()
        mock.createHandler = { _, archiveURL, _, onProgress in
            onProgress(ArchiveProgress(fractionCompleted: 0.5, currentFile: "/path/to/hello.txt"))
            try Data("zip".utf8).write(to: archiveURL)
            onProgress(ArchiveProgress(fractionCompleted: 1.0, currentFile: "/path/to/hello.txt"))
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [fileURL])

        let progressState = ProgressState()
        progressState.operationProgress = 0.75
        progressState.currentFileName = "stale.txt"

        await coordinator.compress(appState: appState, progressState: progressState)

        #expect(progressState.operationProgress == 1.0)
        #expect(progressState.currentFileName == "hello.txt")
        #expect(!progressState.isOperationInProgress)
        #expect(progressState.onCancel == nil)
        #expect(appState.lastError == nil)
    }

    // MARK: - Extract Unique Naming & Unwrapping

    @Test func extract_twiceUsesUniqueFolderAndHandlesSameNameUnwrap() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let srcDir = tmp.appendingPathComponent("src")
        let innerDir = srcDir.appendingPathComponent("bundle/bundle")
        try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
        try "payload".write(to: srcDir.appendingPathComponent("bundle/item.txt"), atomically: true, encoding: .utf8)

        let archiveURL = tmp.appendingPathComponent("bundle.zip")
        let realEngine = Bento7zEngine()
        try await realEngine.create(
            from: [srcDir.appendingPathComponent("bundle")],
            to: archiveURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let coordinator = CompressionCoordinator(engine: realEngine)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        appState.unwrapSingleTopDirectory = true

        await coordinator.browseArchive(at: archiveURL, appState: appState)
        let progressState = ProgressState()

        await coordinator.extract(appState: appState, progressState: progressState)
        let firstOutput = tmp.appendingPathComponent("bundle")
        #expect(fm.fileExists(atPath: firstOutput.appendingPathComponent("item.txt").path))

        // Second extraction creates "bundle 2" instead of overwriting "bundle"
        await coordinator.extract(appState: appState, progressState: progressState)
        let secondOutput = tmp.appendingPathComponent("bundle 2")
        #expect(fm.fileExists(atPath: secondOutput.appendingPathComponent("item.txt").path))
    }

    // MARK: - Add & Remove Refresh

    @Test func addAndRemoveEntries_refreshesBrowseTreeViaListEntries() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)
        try "b".write(to: fileB, atomically: true, encoding: .utf8)

        let archiveURL = tmp.appendingPathComponent("archive.zip")
        let engine = Bento7zEngine()
        try await engine.create(from: [fileA], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        let progressState = ProgressState()

        await coordinator.browseArchive(at: archiveURL, appState: appState)
        #expect(appState.fileEntries.map(\.name) == ["a.txt"])

        await coordinator.addEntries(appState: appState, urls: [fileB], progressState: progressState)
        #expect(Set(appState.fileEntries.map(\.name)) == ["a.txt", "b.txt"])
        #expect(appState.fileEntries.allSatisfy { $0.isFromArchive })

        let toRemove = appState.fileEntries.filter { $0.name == "a.txt" }
        await coordinator.removeEntries(appState: appState, entries: toRemove, progressState: progressState)
        #expect(appState.fileEntries.map(\.name) == ["b.txt"])
    }

    // MARK: - Cancellation

    @Test func cancelOperation_abortsActiveOperationAndCleansUp() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("data.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        let mock = MockArchiveEngine()
        mock.createHandler = { _, archiveURL, _, _ in
            try Data("partial".utf8).write(to: archiveURL)
            try await Task.sleep(for: .seconds(10))
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [fileURL])

        let progressState = ProgressState()
        let opTask = Task {
            await coordinator.compress(appState: appState, progressState: progressState)
        }

        try await Task.sleep(for: .milliseconds(100))
        coordinator.cancelOperation(progressState: progressState)
        await opTask.value

        #expect(!progressState.isOperationInProgress)
        #expect(progressState.onCancel == nil)
        #expect(appState.lastError == nil)
        #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("data.zip").path))
    }

    // MARK: - DragDropManager

    @Test func dragDropManager_preparesLocalAndArchiveEntries() async throws {
        let tmp = try makeTempDir()
        defer {
            try? fm.removeItem(at: tmp)
            DragDropManager.shared.cleanup()
        }

        let fileURL = tmp.appendingPathComponent("dragme.txt")
        try "drag-payload".write(to: fileURL, atomically: true, encoding: .utf8)

        // Local entry returns original URL
        let localEntry = FileEntry(url: fileURL, name: "dragme.txt", isFromArchive: false)
        let localResult = await DragDropManager.shared.prepareForDrag(localEntry, sourceArchiveURL: nil)
        #expect(localResult == fileURL)

        // Archive entry extracts only requested entry
        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("drag.zip")
        try await engine.create(from: [fileURL], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let entries = try await engine.listEntries(in: archiveURL)
        let archiveEntry = try #require(entries.first(where: { $0.name == "dragme.txt" }))
        let draggedURL = try #require(await DragDropManager.shared.prepareForDrag(archiveEntry, sourceArchiveURL: archiveURL))
        #expect(fm.fileExists(atPath: draggedURL.path))
        #expect(try String(contentsOf: draggedURL, encoding: .utf8) == "drag-payload")
    }

    @Test func dragDropManager_rejectsUnsafeNamesAndPropagatesPasswordErrors() async throws {
        let tmp = try makeTempDir()
        defer {
            try? fm.removeItem(at: tmp)
            DragDropManager.shared.cleanup()
        }

        let fileURL = tmp.appendingPathComponent("secret.txt")
        try "secret-payload".write(to: fileURL, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("locked.7z")
        try await engine.create(
            from: [fileURL],
            to: archiveURL,
            settings: CompressionSettings(format: .sevenZip, password: "pw123")
        ) { _ in }

        let entries = try await engine.listEntries(in: archiveURL, password: "pw123")
        let entry = try #require(entries.first)

        // Password error propagates via throwing API instead of returning nil silently
        do {
            _ = try await DragDropManager.shared.prepareForDragThrowing(entry, sourceArchiveURL: archiveURL, password: nil)
            #expect(Bool(false), "Expected password error")
        } catch let err as Bento7zError {
            #expect(err == .passwordRequired || err == .wrongPassword)
        }

        // Unsafe entry name is rejected
        let evilEntry = FileEntry(
            url: URL(fileURLWithPath: "/archive-root/secret.txt"),
            name: "../evil.txt",
            isFromArchive: true,
            archiveRelativePath: "secret.txt"
        )
        do {
            _ = try await DragDropManager.shared.prepareForDragThrowing(evilEntry, sourceArchiveURL: archiveURL, password: "pw123")
            #expect(Bool(false), "Expected INVALID_PATH error")
        } catch let err as Bento7zError {
            if case .operationFailed(_, let code) = err {
                #expect(code == "INVALID_PATH")
            } else {
                #expect(Bool(false), "Expected INVALID_PATH")
            }
        }
    }

    @Test func extract_headerUnencryptedArchive_retriesExtractionOnSubmitPassword() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("doc.txt")
        try "classified".write(to: fileURL, atomically: true, encoding: .utf8)

        // ZIP encrypts file payloads while leaving headers readable during list
        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("header_open.zip")
        try await engine.create(
            from: [fileURL],
            to: archiveURL,
            settings: CompressionSettings(format: .zip, password: "unlock-me")
        ) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        #expect(appState.mode == .browseArchive)
        #expect(!appState.needsPasswordPrompt)

        let progressState = ProgressState()
        await coordinator.extract(appState: appState, progressState: progressState)

        #expect(appState.needsPasswordPrompt)
        #expect(!appState.isPasswordRetryError)
        #expect(appState.pendingPasswordAction == .extract(archiveURL, entries: nil, chooseDestination: false))

        await coordinator.submitPassword("wrong-pw", appState: appState, progressState: progressState)
        #expect(appState.needsPasswordPrompt)
        #expect(appState.isPasswordRetryError)

        await coordinator.submitPassword("unlock-me", appState: appState, progressState: progressState)
        #expect(!appState.needsPasswordPrompt)
        #expect(!appState.isPasswordRetryError)
        #expect(appState.pendingPasswordAction == nil)
        #expect(appState.archivePassword == "unlock-me")

        let extractedFile = tmp.appendingPathComponent("header_open/doc.txt")
        #expect(fm.fileExists(atPath: extractedFile.path))
        #expect(try String(contentsOf: extractedFile, encoding: .utf8) == "classified")
    }

    @Test func compress_preservesDirectoryWithDotsAndSanitizesArchiveName() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let versionedDir = tmp.appendingPathComponent("Project.v1.0")
        try fm.createDirectory(at: versionedDir, withIntermediateDirectories: true)
        try "hello".write(to: versionedDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        var recordedDestinations: [URL] = []
        let mock = MockArchiveEngine()
        mock.createHandler = { _, archiveURL, _, _ in
            recordedDestinations.append(archiveURL)
            try Data("zip".utf8).write(to: archiveURL)
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [versionedDir])

        // Empty archiveName preserves dots in directory name
        let progressState = ProgressState()
        await coordinator.compress(appState: appState, progressState: progressState)
        #expect(recordedDestinations.last?.lastPathComponent == "Project.v1.0.zip")

        // Bare/dirty archiveName is sanitized and gets format extension appended
        appState.compressionSettings.archiveName = "  my/dirty:backup  "
        await coordinator.compress(appState: appState, progressState: progressState)
        #expect(recordedDestinations.last?.lastPathComponent == "mydirtybackup.zip")
    }

    @Test func coordinator_ignoresLateProgressAfterCompletionAndPreventsReentrantCompress() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("data.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        let mock = MockArchiveEngine()
        var createCount = 0
        mock.createHandler = { _, archiveURL, _, onProgress in
            createCount += 1
            onProgress(ArchiveProgress(fractionCompleted: 0.4, currentFile: "working.txt"))
            try await Task.sleep(for: .milliseconds(80))
            try Data("zip".utf8).write(to: archiveURL)
            // Schedule a late progress update after create returns
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                onProgress(ArchiveProgress(fractionCompleted: 0.25, currentFile: "stale.txt"))
            }
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [fileURL])

        let progressState = ProgressState()
        async let first: Void = coordinator.compress(appState: appState, progressState: progressState)
        try await Task.sleep(for: .milliseconds(20))
        // Second re-entrant call while first is active must be ignored
        await coordinator.compress(appState: appState, progressState: progressState)
        await first

        #expect(createCount == 1)

        // Wait past the late callback delay and verify progressState was not overwritten
        try await Task.sleep(for: .milliseconds(120))
        #expect(progressState.operationProgress == 1.0)
        #expect(progressState.currentFileName != "stale.txt")
        #expect(!progressState.isOperationInProgress)
    }

    @Test func perWindowSheetProgress_alwaysResetsIsOperationInProgressOnError() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent("fail.txt")
        try "boom".write(to: fileURL, atomically: true, encoding: .utf8)

        let mock = MockArchiveEngine()
        mock.createHandler = { _, _, _, _ in
            throw Bento7zError.operationFailed("Disk full", "IO_ERROR")
        }

        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [fileURL])

        let progressState = ProgressState()
        await coordinator.compress(appState: appState, progressState: progressState)

        #expect(!progressState.isOperationInProgress)
        #expect(progressState.onCancel == nil)
        #expect(appState.lastError != nil)
    }

    @Test func dragDropManager_concurrentSameBasenameExtractionsDoNotCollide() async throws {
        let tmp = try makeTempDir()
        defer {
            try? fm.removeItem(at: tmp)
            DragDropManager.shared.cleanup()
        }

        let dirA = tmp.appendingPathComponent("a")
        let dirB = tmp.appendingPathComponent("b")
        try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
        try "alpha-readme".write(to: dirA.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "beta-readme".write(to: dirB.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("collision.zip")
        try await engine.create(
            from: [dirA, dirB],
            to: archiveURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let entries = try await engine.listEntries(in: archiveURL)
        func findEntry(_ targetPath: String, in list: [FileEntry]) -> FileEntry? {
            for item in list {
                if item.archiveRelativePath == targetPath { return item }
                if let children = item.children, let match = findEntry(targetPath, in: children) { return match }
            }
            return nil
        }

        let entryA = try #require(findEntry("a/README.md", in: entries))
        let entryB = try #require(findEntry("b/README.md", in: entries))

        async let extractedA1 = DragDropManager.shared.prepareForDragThrowing(entryA, sourceArchiveURL: archiveURL)
        async let extractedB = DragDropManager.shared.prepareForDragThrowing(entryB, sourceArchiveURL: archiveURL)
        async let extractedA2 = DragDropManager.shared.prepareForDragThrowing(entryA, sourceArchiveURL: archiveURL)

        let urlA1 = try #require(await extractedA1)
        let urlB = try #require(await extractedB)
        let urlA2 = try #require(await extractedA2)

        #expect(urlA1 != urlB)
        #expect(urlA1 == urlA2)
        #expect(urlA1.lastPathComponent == "README.md")
        #expect(urlB.lastPathComponent == "README.md")
        #expect(try String(contentsOf: urlA1, encoding: .utf8) == "alpha-readme")
        #expect(try String(contentsOf: urlB, encoding: .utf8) == "beta-readme")
    }

    @Test func dragDropManager_windowResetPreservesTempFilesAndMutationInvalidatesCache() async throws {
        let tmp = try makeTempDir()
        defer {
            try? fm.removeItem(at: tmp)
            DragDropManager.shared.cleanup()
        }

        let itemV1 = tmp.appendingPathComponent("item.txt")
        let extraFile = tmp.appendingPathComponent("extra.txt")
        try "version-1".write(to: itemV1, atomically: true, encoding: .utf8)
        try "extra".write(to: extraFile, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("mutable.zip")
        try await engine.create(from: [itemV1], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let windowA = AppState()
        let windowB = AppState()
        await coordinator.browseArchive(at: archiveURL, appState: windowA)

        let entryV1 = try #require(windowA.fileEntries.first(where: { $0.name == "item.txt" }))
        let firstExtracted = try #require(await DragDropManager.shared.prepareForDragThrowing(entryV1, sourceArchiveURL: archiveURL))
        #expect(try String(contentsOf: firstExtracted, encoding: .utf8) == "version-1")

        // Resetting another window must NOT wipe temp files belonging to Window A
        windowB.reset()
        #expect(fm.fileExists(atPath: firstExtracted.path))
        #expect(try String(contentsOf: firstExtracted, encoding: .utf8) == "version-1")

        // Mutating the archive via coordinator invalidates the drag cache without deleting existing temp files
        let progressState = ProgressState()
        await coordinator.addEntries(appState: windowA, urls: [extraFile], progressState: progressState)
        #expect(fm.fileExists(atPath: firstExtracted.path))

        let entryAfterAdd = try #require(windowA.fileEntries.first(where: { $0.name == "item.txt" }))
        let secondExtracted = try #require(await DragDropManager.shared.prepareForDragThrowing(entryAfterAdd, sourceArchiveURL: archiveURL))
        #expect(secondExtracted != firstExtracted)
        #expect(try String(contentsOf: secondExtracted, encoding: .utf8) == "version-1")

        // Overwriting the archive on disk directly (changing size/mtime) also bypasses stale cache entries
        try "version-2-longer-payload".write(to: itemV1, atomically: true, encoding: .utf8)
        try fm.removeItem(at: archiveURL)
        try await engine.create(from: [itemV1], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let thirdExtracted = try #require(await DragDropManager.shared.prepareForDragThrowing(entryAfterAdd, sourceArchiveURL: archiveURL))
        #expect(thirdExtracted != secondExtracted)
        #expect(try String(contentsOf: thirdExtracted, encoding: .utf8) == "version-2-longer-payload")
    }

    @Test func compress_omitsNestedItemsRemovedInCompressMode() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let projectDir = tmp.appendingPathComponent("Bundle")
        let skipDir = projectDir.appendingPathComponent("Cache")
        try fm.createDirectory(at: skipDir, withIntermediateDirectories: true)
        try "keep".write(to: projectDir.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "skip-file".write(to: projectDir.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)
        try "skip-dir-file".write(to: skipDir.appendingPathComponent("temp.dat"), atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let appState = AppState()
        appState.coordinator = CompressionCoordinator(engine: engine)
        appState.revealInFinderAfterExtract = false

        await appState.loadFilesAsync(from: [projectDir])
        let bundleNode = try #require(appState.rootNodes.first)
        await appState.loadChildrenIfNeededAsync(for: bundleNode)

        let skipFileNode = try #require(bundleNode.children?.first(where: { $0.name == "skip.txt" }))
        let skipDirNode = try #require(bundleNode.children?.first(where: { $0.name == "Cache" }))
        appState.selectedEntryIDs = [skipFileNode.id, skipDirNode.id]
        appState.removeSelectedEntries()

        let outputArchive = tmp.appendingPathComponent("Bundle.zip")
        appState.compressionSettings.format = .zip
        appState.compressionSettings.archiveName = "Bundle.zip"

        let progressState = ProgressState()
        await appState.coordinator.compress(appState: appState, progressState: progressState)

        #expect(appState.lastError == nil)
        #expect(fm.fileExists(atPath: outputArchive.path))

        let entries = try await engine.listEntries(in: outputArchive)
        func flattenPaths(_ list: [FileEntry]) -> [String] {
            list.flatMap { entry -> [String] in
                let selfPaths = entry.isDirectory ? [] : [entry.archiveRelativePath ?? entry.name]
                return selfPaths + flattenPaths(entry.children ?? [])
            }
        }
        let archivedFiles = flattenPaths(entries)
        #expect(archivedFiles == ["Bundle/keep.txt"])
    }

    @Test func transferManager_tracksTelemetrySpeedRatioAndLifecycleCleanly() async throws {
        let manager = TransferManager()
        let start = Date(timeIntervalSince1970: 1_000)
        let destURL = URL(fileURLWithPath: "/tmp/example.7z")
        let task = TransferTask(
            kind: .compress,
            title: "Compressing…",
            totalBytes: 1_000_000,
            totalFiles: 10,
            destinationURL: destURL,
            startedAt: start
        )
        manager.register(task)
        #expect(manager.hasActiveTasks)
        #expect(manager.tasks.count == 1)

        task.apply(
            ArchiveProgress(
                fractionCompleted: 0.5,
                currentFile: "folder/photo.png",
                processedBytes: 500_000,
                totalBytes: 1_000_000,
                isFileEvent: true
            ),
            now: start.addingTimeInterval(2.0)
        )
        task.tick(now: start.addingTimeInterval(2.0), polledOutputSize: 250_000)

        #expect(task.currentFileName == "photo.png")
        #expect(task.processedFiles == 1)
        #expect(task.processedBytes == 500_000)
        #expect(task.elapsedSeconds == 2.0)
        #expect(task.bytesPerSecond == 250_000)
        #expect(task.estimatedRemainingSeconds == 2.0)
        #expect(task.compressedBytes == 250_000)
        #expect(task.compressionRatioPercent == 50)

        task.markCompleted(now: start.addingTimeInterval(4.0), finalOutputSize: 400_000)
        #expect(task.isCompleted)
        #expect(!task.isCancellable)
        #expect(task.fractionCompleted == 1.0)
        #expect(task.processedBytes == 1_000_000)
        #expect(task.estimatedRemainingSeconds == nil)
        #expect(task.compressionRatioPercent == 40)

        manager.remove(id: task.id)
        #expect(!manager.hasActiveTasks)
    }

    @Test func coordinator_registersAndRemovesTransferTaskAcrossCompression() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("hello.txt")
        try Data(repeating: 0x61, count: 4096).write(to: file)

        let manager = TransferManager()
        let coordinator = CompressionCoordinator(engine: Bento7zEngine(), transferManager: manager)
        let appState = AppState()
        appState.coordinator = coordinator
        appState.revealInFinderAfterExtract = false

        await appState.loadFilesAsync(from: [file])
        appState.compressionSettings.format = .zip
        appState.compressionSettings.archiveName = "hello.zip"

        let progressState = ProgressState()
        await coordinator.compress(appState: appState, progressState: progressState)

        #expect(appState.lastError == nil)
        #expect(!progressState.isOperationInProgress)
        #expect(!manager.hasActiveTasks)
    }

    @Test func browseArchive_switchesModeImmediatelyBeforeAsyncListingCompletes() async throws {
        struct DelayedListEngine: ArchiveEngine {
            let entries: [FileEntry]
            func listEntries(in archiveURL: URL, password: String?) async throws -> [FileEntry] {
                try await Task.sleep(for: .milliseconds(80))
                return entries
            }
            func extract(archiveURL: URL, entries: [FileEntry]?, to destinationURL: URL, password: String?, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {}
            func create(from sourceURLs: [URL], to archiveURL: URL, settings: CompressionSettings, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {}
            func removeEntries(from archiveURL: URL, entries: [FileEntry], password: String?) async throws {}
            func addEntries(to archiveURL: URL, from sourceURLs: [URL], password: String?, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {}
        }

        let fakeArchive = URL(fileURLWithPath: "/tmp/huge-test.tar.gz")
        let sampleEntry = FileEntry(
            url: URL(fileURLWithPath: "/archive-root/readme.txt"),
            name: "readme.txt",
            isDirectory: false,
            size: 128,
            isFromArchive: true,
            archiveRelativePath: "readme.txt"
        )
        let coordinator = CompressionCoordinator(engine: DelayedListEngine(entries: [sampleEntry]))
        let appState = AppState()
        appState.coordinator = coordinator

        let browseTask = Task {
            await coordinator.browseArchive(at: fakeArchive, appState: appState)
        }
        try await Task.sleep(for: .milliseconds(15))

        // Workspace UI must switch immediately while listing runs in the background
        #expect(appState.mode == .browseArchive)
        #expect(appState.sourceArchiveURL == fakeArchive)
        #expect(appState.isLoading)
        #expect(appState.rootNodes.isEmpty)

        await browseTask.value
        #expect(!appState.isLoading)
        #expect(appState.rootNodes.map(\.name) == ["readme.txt"])
    }

    @Test func detachWindowProgress_backToHomeDoesNotCancelRunningTransfer() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        struct SlowCreateEngine: ArchiveEngine {
            func listEntries(in archiveURL: URL, password: String?) async throws -> [FileEntry] { [] }
            func extract(archiveURL: URL, entries: [FileEntry]?, to destinationURL: URL, password: String?, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {}
            func create(from sourceURLs: [URL], to archiveURL: URL, settings: CompressionSettings, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {
                for i in 1...100 {
                    onProgress(ArchiveProgress(
                        fractionCompleted: Double(i) / 100.0,
                        currentFile: "file_\(i).txt",
                        processedBytes: Int64(i * 1024),
                        totalBytes: 102_400,
                        isFileEvent: true
                    ))
                    if i == 10 {
                        try await Task.sleep(for: .milliseconds(90))
                    }
                }
                try Data("archive-ok".utf8).write(to: archiveURL)
            }
            func removeEntries(from archiveURL: URL, entries: [FileEntry], password: String?) async throws {}
            func addEntries(to archiveURL: URL, from sourceURLs: [URL], password: String?, onProgress: @escaping @Sendable (ArchiveProgress) -> Void) async throws {}
        }

        let sourceFile = tmp.appendingPathComponent("payload.txt")
        try "hello".write(to: sourceFile, atomically: true, encoding: .utf8)

        let manager = TransferManager()
        let coordinator = CompressionCoordinator(engine: SlowCreateEngine(), transferManager: manager)
        let appState = AppState()
        appState.coordinator = coordinator
        appState.revealInFinderAfterExtract = false
        await appState.loadFilesAsync(from: [sourceFile])
        appState.compressionSettings.format = .zip
        appState.compressionSettings.archiveName = "detached.zip"

        let progressState = ProgressState()
        let compressTask = Task {
            await coordinator.compress(appState: appState, progressState: progressState)
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(manager.hasActiveTasks)

        // Simulate clicking Back (<) in the window toolbar
        coordinator.detachWindowProgress(progressState)
        appState.reset()
        #expect(appState.mode == .empty)
        #expect(!progressState.isOperationInProgress)
        #expect(manager.hasActiveTasks)

        // The detached transfer must continue and finish writing the output archive cleanly
        await compressTask.value
        let expectedOutput = tmp.appendingPathComponent("detached.zip")
        #expect(fm.fileExists(atPath: expectedOutput.path))
        #expect(!manager.hasActiveTasks)
    }

    // MARK: - P0 Coordinator, Conflict Resolution & Cleanup

    @Test func extract_selectiveEntries_extractsDirectlyWithoutArchiveStemWrapper() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let srcDir = tmp.appendingPathComponent("src")
        let nestedDir = srcDir.appendingPathComponent("folder")
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let fileA = nestedDir.appendingPathComponent("a.txt")
        let fileB = srcDir.appendingPathComponent("b.txt")
        try "alpha".write(to: fileA, atomically: true, encoding: .utf8)
        try "bravo".write(to: fileB, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("bundle_selective.zip")
        try await engine.create(
            from: [nestedDir, fileB],
            to: archiveURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        let entryB = try #require(appState.fileEntries.first(where: { $0.name == "b.txt" }))
        let progressState = ProgressState()
        await coordinator.extract(appState: appState, progressState: progressState, entries: [entryB])

        #expect(appState.lastError == nil)
        // Must extract directly into tmp/b.txt without wrapping inside tmp/bundle_selective/
        let directURL = tmp.appendingPathComponent("b.txt")
        let wrappedURL = tmp.appendingPathComponent("bundle_selective/b.txt")
        #expect(fm.fileExists(atPath: directURL.path))
        #expect(try String(contentsOf: directURL, encoding: .utf8) == "bravo")
        #expect(!fm.fileExists(atPath: wrappedURL.path))
    }

    @Test func extract_conflictPolicies_overwriteSkipAndRename() async throws {
        let policies: [ExtractConflictPolicy] = [.overwrite, .skip, .rename]
        let engine = Bento7zEngine()

        for policy in policies {
            let tmp = try makeTempDir()
            defer { try? fm.removeItem(at: tmp) }

            let srcFile = tmp.appendingPathComponent("file.txt")
            try "incoming".write(to: srcFile, atomically: true, encoding: .utf8)

            let archiveDir = tmp.appendingPathComponent("archives")
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            let archiveURL = archiveDir.appendingPathComponent("conflict.zip")
            try await engine.create(from: [srcFile], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

            // Pre-create conflicting file.txt inside destination directory (archiveDir)
            let existingFile = archiveDir.appendingPathComponent("file.txt")
            try "existing".write(to: existingFile, atomically: true, encoding: .utf8)

            let coordinator = CompressionCoordinator(engine: engine)
            let appState = AppState()
            appState.revealInFinderAfterExtract = false
            appState.extractConflictPolicy = policy
            await coordinator.browseArchive(at: archiveURL, appState: appState)

            let entry = try #require(appState.fileEntries.first(where: { $0.name == "file.txt" }))
            let progressState = ProgressState()
            await coordinator.extract(appState: appState, progressState: progressState, entries: [entry])

            #expect(appState.lastError == nil)
            switch policy {
            case .overwrite:
                #expect(try String(contentsOf: existingFile, encoding: .utf8) == "incoming")
                #expect(!fm.fileExists(atPath: archiveDir.appendingPathComponent("file 2.txt").path))
            case .skip:
                #expect(try String(contentsOf: existingFile, encoding: .utf8) == "existing")
                #expect(!fm.fileExists(atPath: archiveDir.appendingPathComponent("file 2.txt").path))
            case .rename:
                let renamedFile = archiveDir.appendingPathComponent("file 2.txt")
                #expect(try String(contentsOf: existingFile, encoding: .utf8) == "existing")
                #expect(fm.fileExists(atPath: renamedFile.path))
                #expect(try String(contentsOf: renamedFile, encoding: .utf8) == "incoming")
            case .ask:
                break
            }
        }
    }

    @Test func extract_moveArchiveToTrashAfterExtract_trashesSourceArchiveOnFullExtract() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let srcFile = tmp.appendingPathComponent("payload.txt")
        try "trash-after-extract".write(to: srcFile, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveName = "trashme_\(UUID().uuidString).zip"
        let archiveURL = tmp.appendingPathComponent(archiveName)
        try await engine.create(from: [srcFile], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        appState.moveArchiveToTrashAfterExtract = true
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        let progressState = ProgressState()
        await coordinator.extract(appState: appState, progressState: progressState)

        let stem = archiveURL.deletingPathExtension().lastPathComponent
        let extractedFile = tmp.appendingPathComponent("\(stem)/payload.txt")
        #expect(fm.fileExists(atPath: extractedFile.path))
        #expect(try String(contentsOf: extractedFile, encoding: .utf8) == "trash-after-extract")
        #expect(!fm.fileExists(atPath: archiveURL.path))
        #expect(appState.mode == .empty)
    }

    @Test func testArchive_coordinatorSetsTestArchiveResultOnSuccessAndFailure() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try "aaa".write(to: fileA, atomically: true, encoding: .utf8)
        try "bbb".write(to: fileB, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("verify.zip")
        try await engine.create(from: [fileA, fileB], to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        let progressState = ProgressState()
        await coordinator.testArchive(appState: appState, progressState: progressState)

        let result = try #require(appState.testArchiveResult)
        #expect(result.passed)
        #expect(result.archiveName == "verify.zip")
        #expect(result.itemsCount == 2)
        #expect(result.errorMessage == nil)
        #expect(!progressState.isOperationInProgress)

        // Now truncate the archive to corrupt it and verify failed testArchiveResult is populated
        let bytes = try Data(contentsOf: archiveURL)
        try bytes.prefix(24).write(to: archiveURL)

        await coordinator.testArchive(appState: appState, progressState: progressState)
        let failedResult = try #require(appState.testArchiveResult)
        #expect(!failedResult.passed)
        #expect(failedResult.archiveName == "verify.zip")
        #expect(failedResult.itemsCount == 0)
        #expect(failedResult.errorMessage != nil)
    }

    @Test func dragDropManager_cleanupStaleTempDirectories_removesOrphanedDirectoriesOnly() async throws {
        let tempRoot = fm.temporaryDirectory
        var deadPID: pid_t = 999_999
        while deadPID > 10_000 {
            if Darwin.kill(deadPID, 0) == -1 && errno == ESRCH {
                break
            }
            deadPID -= 1
        }
        #expect(Darwin.kill(deadPID, 0) == -1 && errno == ESRCH)

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let deadPIDDir = tempRoot.appendingPathComponent("BentoZip-drag-\(deadPID)-\(UUID().uuidString)", isDirectory: true)
        let livePIDDir = tempRoot.appendingPathComponent("BentoZip-drag-\(currentPID)-\(UUID().uuidString)", isDirectory: true)
        let unrelatedDir = tempRoot.appendingPathComponent("BentoZip-keep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: deadPIDDir, withIntermediateDirectories: true)
        try "stale".write(to: deadPIDDir.appendingPathComponent("stale.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: livePIDDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelatedDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: deadPIDDir)
            try? fm.removeItem(at: livePIDDir)
            try? fm.removeItem(at: unrelatedDir)
        }

        DragDropManager.shared.cleanupStaleTempDirectories()

        for _ in 0..<100 {
            if !fm.fileExists(atPath: deadPIDDir.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!fm.fileExists(atPath: deadPIDDir.path))
        #expect(fm.fileExists(atPath: livePIDDir.path))
        #expect(fm.fileExists(atPath: unrelatedDir.path))
    }

    @Test func mergeStagedContents_regularFileCollidingWithDestinationURL_respectsOverwriteSkipAndRename() async throws {
        let coordinator = CompressionCoordinator()

        for policy in [ExtractConflictPolicy.overwrite, .skip, .rename] {
            let tmp = try makeTempDir()
            defer { try? fm.removeItem(at: tmp) }

            let stagingDir = tmp.appendingPathComponent("stage", isDirectory: true)
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try "extracted-payload".write(
                to: stagingDir.appendingPathComponent("hello.txt"),
                atomically: true,
                encoding: .utf8
            )

            let destURL = tmp.appendingPathComponent("Output")
            try "blocking-regular-file".write(to: destURL, atomically: true, encoding: .utf8)

            let result = try await coordinator.mergeStagedContents(
                from: stagingDir,
                into: destURL,
                initialPolicy: policy,
                appState: nil
            )

            switch policy {
            case .overwrite:
                #expect(result.finalDestinationURL.standardizedFileURL == destURL.standardizedFileURL)
                var isDir: ObjCBool = false
                #expect(fm.fileExists(atPath: destURL.path, isDirectory: &isDir) && isDir.boolValue)
                #expect(try String(contentsOf: destURL.appendingPathComponent("hello.txt"), encoding: .utf8) == "extracted-payload")
            case .skip:
                var isDir: ObjCBool = false
                #expect(fm.fileExists(atPath: destURL.path, isDirectory: &isDir) && !isDir.boolValue)
                #expect(try String(contentsOf: destURL, encoding: .utf8) == "blocking-regular-file")
                #expect(result.mergedTopLevelURLs.isEmpty)
            case .rename:
                let renamedDest = tmp.appendingPathComponent("Output 2")
                #expect(result.finalDestinationURL.standardizedFileURL == renamedDest.standardizedFileURL)
                var origIsDir: ObjCBool = false
                #expect(fm.fileExists(atPath: destURL.path, isDirectory: &origIsDir) && !origIsDir.boolValue)
                #expect(try String(contentsOf: destURL, encoding: .utf8) == "blocking-regular-file")
                #expect(try String(contentsOf: renamedDest.appendingPathComponent("hello.txt"), encoding: .utf8) == "extracted-payload")
            case .ask:
                break
            }
        }
    }

    @Test func extract_closeWindowAfterExtract_skipsCloseWhenDetachedOrSwitchedArchive() async throws {
        let tmp = try makeTempDir()
        defer { try? fm.removeItem(at: tmp) }

        let archiveA = tmp.appendingPathComponent("first.zip")
        let archiveB = tmp.appendingPathComponent("second.zip")
        try Data("a".utf8).write(to: archiveA)
        try Data("b".utf8).write(to: archiveB)

        let mock = MockArchiveEngine()
        mock.extractHandler = { _, _, destURL, _, _ in
            try? FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
            try Data("extracted".utf8).write(to: destURL.appendingPathComponent("item.txt"))
            try await Task.sleep(for: .milliseconds(80))
        }

        // Case 1: User detaches and returns to .empty while extraction is running -> must NOT close window
        let coordinator = CompressionCoordinator(engine: mock)
        let appState = AppState()
        appState.revealInFinderAfterExtract = false
        appState.closeWindowAfterExtract = true
        appState.mode = .browseArchive
        appState.sourceArchiveURL = archiveA
        var closeCount = 0
        appState.onRequestCloseWindow = { closeCount += 1 }

        let progressA = ProgressState()
        let taskA = Task {
            await coordinator.extract(appState: appState, progressState: progressA)
        }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.detachWindowProgress(progressA)
        appState.reset()
        await taskA.value
        #expect(closeCount == 0)

        // Case 2: User detaches and switches to archiveB while archiveA extracts -> must NOT close window
        appState.revealInFinderAfterExtract = false
        appState.closeWindowAfterExtract = true
        appState.mode = .browseArchive
        appState.sourceArchiveURL = archiveA
        let progressB = ProgressState()
        let taskB = Task {
            await coordinator.extract(appState: appState, progressState: progressB)
        }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.detachWindowProgress(progressB)
        appState.sourceArchiveURL = archiveB
        await taskB.value
        #expect(closeCount == 0)

        // Case 3: Still viewing the same archive when extraction finishes -> MUST invoke onRequestCloseWindow
        appState.sourceArchiveURL = archiveA
        let progressC = ProgressState()
        await coordinator.extract(appState: appState, progressState: progressC)
        #expect(closeCount == 1)
    }
}
