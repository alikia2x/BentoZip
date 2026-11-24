import Foundation
import SwiftData
import Testing
import BentoZipCore

@Suite(.serialized) @MainActor
struct AppStateTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("AppStateTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadFilesAsync_buildsTreeOffMainActorAndComputesTotals() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Project")
        let nested = folder.appendingPathComponent("Sources")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let rootFile = dir.appendingPathComponent("notes.txt")
        let nestedFile = nested.appendingPathComponent("main.swift")
        try Data(repeating: 0x41, count: 150).write(to: rootFile)
        try Data(repeating: 0x42, count: 350).write(to: nestedFile)

        let appState = AppState()
        await appState.loadFilesAsync(from: [rootFile, folder])

        #expect(appState.mode == .compress)
        #expect(appState.showInspector)
        #expect(!appState.isLoading)
        #expect(appState.fileEntries.count == 2)
        #expect(appState.totalSize == 500)
        #expect(appState.totalPackedSize == nil)

        // Directories sort first
        let projectEntry = appState.fileEntries[0]
        #expect(projectEntry.name == "Project")
        #expect(projectEntry.isDirectory)
        #expect(projectEntry.size == 350)

        appState.navigateInto(projectEntry)
        #expect(appState.canNavigateUp)
        #expect(appState.displayedEntries.count == 1)

        appState.selectAll()
        #expect(appState.selectedEntries.count == 1)

        appState.clearSelection()
        #expect(appState.selectedEntryIDs.isEmpty)

        appState.navigateUp()
        #expect(!appState.canNavigateUp)
        #expect(appState.displayedEntries.count == 2)
    }

    @Test func addEntriesAsync_deduplicatesAndIgnoresBrowseArchiveMode() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try "aaa".write(to: fileA, atomically: true, encoding: .utf8)
        try "bbb".write(to: fileB, atomically: true, encoding: .utf8)

        let appState = AppState()
        await appState.loadFilesAsync(from: [fileA])
        #expect(appState.fileEntries.count == 1)

        // Adding duplicate + new file only adds new file
        await appState.addEntriesAsync(from: [fileA, fileB])
        #expect(appState.fileEntries.count == 2)

        // Switching to browseArchive prevents local addEntries mutation
        appState.mode = .browseArchive
        let fileC = dir.appendingPathComponent("c.txt")
        try "ccc".write(to: fileC, atomically: true, encoding: .utf8)
        await appState.addEntriesAsync(from: [fileC])
        #expect(appState.fileEntries.count == 2)
    }

    @Test func archiveComputedProperties_reflectArchiveEntriesAndFormat() {
        let appState = AppState()
        appState.mode = .browseArchive
        appState.sourceArchiveURL = URL(fileURLWithPath: "/tmp/backup.tar.gz")
        appState.fileEntries = [
            FileEntry(
                url: URL(fileURLWithPath: "/archive-root/dir"),
                name: "dir",
                isDirectory: true,
                size: 0,
                packedSize: nil,
                isEncrypted: false,
                isFromArchive: true,
                archiveRelativePath: "dir",
                children: [
                    FileEntry(
                        url: URL(fileURLWithPath: "/archive-root/dir/secret.txt"),
                        name: "secret.txt",
                        isDirectory: false,
                        size: 1000,
                        packedSize: 400,
                        isEncrypted: true,
                        isFromArchive: true,
                        archiveRelativePath: "dir/secret.txt"
                    )
                ]
            ),
            FileEntry(
                url: URL(fileURLWithPath: "/archive-root/plain.txt"),
                name: "plain.txt",
                isDirectory: false,
                size: 500,
                packedSize: 250,
                isEncrypted: false,
                isFromArchive: true,
                archiveRelativePath: "plain.txt"
            )
        ]

        #expect(appState.totalSize == 1500)
        #expect(appState.totalPackedSize == 650)
        #expect(appState.totalEntryCount == 3)
        #expect(appState.isWritableArchive)
        #expect(!appState.isReadOnlyArchive)
        #expect(appState.isArchiveEncrypted)
        #expect(appState.archiveFormatName == "TAR.GZ")

        // Backend archivePackedSize overrides per-entry sum when positive (e.g. solid 7z)
        appState.archivePackedSize = 320
        #expect(appState.totalPackedSize == 320)

        // Read-only formats (.rar, .gz, .bz2, .xz) report isWritableArchive == false
        for readOnlyName in ["archive.rar", "single.gz", "single.bz2", "single.xz"] {
            appState.sourceArchiveURL = URL(fileURLWithPath: "/tmp/\(readOnlyName)")
            #expect(!appState.isWritableArchive)
            #expect(appState.isReadOnlyArchive)
        }

        // Compress mode is never considered a writable archive
        appState.mode = .compress
        #expect(!appState.isWritableArchive)
    }

    @Test func archiveNamingAndExtensionSyncHelpers() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let versionedDir = dir.appendingPathComponent("Project.v1.0")
        try fm.createDirectory(at: versionedDir, withIntermediateDirectories: true)
        let regularFile = dir.appendingPathComponent("report.pdf")
        try "pdf".write(to: regularFile, atomically: true, encoding: .utf8)

        // Directories preserve dots in their name
        #expect(AppState.defaultArchiveStem(for: [versionedDir]) == "Project.v1.0")
        #expect(AppState.defaultArchiveStem(for: [regularFile]) == "report")
        #expect(AppState.defaultArchiveStem(for: [versionedDir, regularFile]) == "archive")

        let appState = AppState()
        appState.compressionSettings.format = .zip
        appState.compressionSettings.archiveName = "backup.zip"
        #expect(appState.archiveNameWithSyncedExtension(oldFormat: .zip, newFormat: .tarBz2) == "backup.tar.bz2")

        appState.updateCompressionFormat(to: .tarXz)
        #expect(appState.compressionSettings.format == .tarXz)
        #expect(appState.compressionSettings.archiveName == "backup.tar.xz")

        let bareUpdated = CompressionSettings(format: .zip, archiveName: "release").updatingFormat(to: .tarGz)
        #expect(bareUpdated.archiveName == "release.tar.gz")
    }

    @Test func recentArchives_validatedAsynchronouslyAndUpdatedOnSave() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let validZip = dir.appendingPathComponent("valid.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: validZip)
        let missingZip = dir.appendingPathComponent("missing.zip")
        let nonArchive = dir.appendingPathComponent("notes.txt")
        try "text".write(to: nonArchive, atomically: true, encoding: .utf8)

        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let manager = PreferencesManager()
        manager.configure(with: container.mainContext)

        let appState = AppState()
        appState.preferencesManager = manager

        var postedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: PreferencesManager.preferencesDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            postedCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.recordArchive(nonArchive.path)
        manager.recordArchive(missingZip.path)
        manager.recordArchive(validZip.path)

        await appState.refreshRecentArchivesAsync()
        #expect(appState.recentArchiveURLs == [validZip])
        #expect(postedCount == 3)
    }

    @Test func preferencesManager_persistsAndAppliesDefaultsToAppState() throws {
        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let manager = PreferencesManager()
        manager.configure(with: container.mainContext)

        let appState = AppState()
        appState.preferencesManager = manager
        appState.compressionSettings.format = .sevenZip
        appState.compressionSettings.compressionLevel = .best
        appState.compressionSettings.exclusionPatterns = [".git", "*.tmp"]
        appState.revealInFinderAfterExtract = false
        appState.unwrapSingleTopDirectory = false
        appState.savePreferences()

        manager.recordArchive("/tmp/recent.7z")

        // New AppState reading from same PreferencesManager receives persisted settings
        let reloadedState = AppState()
        reloadedState.preferencesManager = manager

        #expect(reloadedState.compressionSettings.format == .sevenZip)
        #expect(reloadedState.compressionSettings.compressionLevel == .best)
        #expect(reloadedState.compressionSettings.exclusionPatterns == [".git", "*.tmp"])
        #expect(!reloadedState.revealInFinderAfterExtract)
        #expect(!reloadedState.unwrapSingleTopDirectory)
        #expect(manager.loadPreferences().recentArchives == ["/tmp/recent.7z"])

        // Reset restores saved preference defaults
        reloadedState.compressionSettings.format = .tar
        reloadedState.reset()
        #expect(reloadedState.mode == .empty)
        #expect(reloadedState.compressionSettings.format == .sevenZip)
    }

    @Test func loadFiles_fireAndForget_entersCompressModeForDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let sub = dir.appendingPathComponent("Album")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 128).write(to: sub.appendingPathComponent("track.wav"))

        let appState = AppState()
        appState.loadFiles(from: [sub])

        for _ in 0..<50 {
            if appState.mode == .compress && !appState.isLoading {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(appState.mode == .compress)
        #expect(appState.showInspector)
        #expect(!appState.isLoading)
        #expect(appState.fileEntries.count == 1)
        #expect(appState.fileEntries[0].name == "Album")
        #expect(appState.totalSize == 128)
        #expect(!appState.fileEntries[0].hasLoadedChildren)

        // Lazy expansion loads immediate children while preserving entry ID
        let originalID = appState.fileEntries[0].id
        appState.loadChildrenIfNeeded(for: appState.fileEntries[0])
        for _ in 0..<50 {
            if appState.fileEntries[0].hasLoadedChildren { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(appState.fileEntries[0].id == originalID)
        #expect(appState.fileEntries[0].hasLoadedChildren)
        #expect(appState.fileEntries[0].children?.count == 1)
        #expect(appState.fileEntries[0].children?[0].name == "track.wav")
    }
}
