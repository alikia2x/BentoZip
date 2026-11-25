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

        await appState.navigateIntoAsync(projectEntry)
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

    @Test func singleSourceOfTruth_preservesFileNodeIdentityAcrossLazyLoadNavigationAndSizeUpdates() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let parentDir = dir.appendingPathComponent("Workspace")
        let childDir = parentDir.appendingPathComponent("Modules")
        try fm.createDirectory(at: childDir, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 200).write(to: childDir.appendingPathComponent("core.swift"))

        let appState = AppState()
        await appState.loadFilesAsync(from: [parentDir])

        let rootNode = try #require(appState.rootNodes.first)
        #expect(appState.node(for: rootNode.id) === rootNode)
        #expect(rootNode.size == 200)
        #expect(rootNode.isExpandable)
        #expect(!rootNode.hasLoadedChildren)
        #expect(appState.lastUpdatedNodeID == rootNode.id)
        #expect(!appState.lastUpdatedNodeReloadChildren)

        // Lazily load immediate children in-place: same FileNode reference, nodeUpdateRevision bumps, structure revision unchanged
        let structureBeforeLazy = appState.treeStructureRevision
        let updateBeforeLazy = appState.nodeUpdateRevision
        await appState.loadChildrenIfNeededAsync(for: rootNode)

        #expect(appState.rootNodes.first === rootNode)
        #expect(rootNode.hasLoadedChildren)
        #expect(appState.treeStructureRevision == structureBeforeLazy)
        #expect(appState.nodeUpdateRevision == updateBeforeLazy + 1)
        #expect(appState.lastUpdatedNodeID == rootNode.id)
        #expect(appState.lastUpdatedNodeReloadChildren)

        let modulesNode = try #require(rootNode.children?.first)
        #expect(modulesNode.name == "Modules")
        #expect(modulesNode.parent === rootNode)
        #expect(appState.node(for: modulesNode.id) === modulesNode)

        // Navigate into rootNode and mutate size in-place: navigationNodes reflects live node without stale copies
        appState.navigateInto(rootNode)
        #expect(appState.navigationNodeIDs == [rootNode.id])
        #expect(appState.navigationNodes.first === rootNode)
        #expect(appState.displayedNodes.first === modulesNode)

        rootNode.size = 999
        #expect(appState.navigationNodes.first?.size == 999)
        #expect(appState.rootNodes.first === appState.navigationNodes.first)

        // Removing root node cleans up both root and descendant IDs from O(1) lookup table
        appState.navigateBack(to: 0)
        appState.selectedEntryIDs = [rootNode.id]
        appState.removeSelectedEntries()
        #expect(appState.rootNodes.isEmpty)
        #expect(appState.node(for: rootNode.id) == nil)
        #expect(appState.node(for: modulesNode.id) == nil)
        #expect(appState.totalSize == 0)
    }

    @Test func selectedNodes_resolvesDeeplyNestedExpandedChildrenInO1() throws {
        let leaf = FileEntry(
            url: URL(fileURLWithPath: "/archive-root/a/b/c/d/deep.txt"),
            name: "deep.txt",
            size: 420,
            isFromArchive: true,
            archiveRelativePath: "a/b/c/d/deep.txt"
        )
        let sibling = FileEntry(
            url: URL(fileURLWithPath: "/archive-root/a/b/mid.txt"),
            name: "mid.txt",
            size: 80,
            isFromArchive: true,
            archiveRelativePath: "a/b/mid.txt"
        )
        let levelD = FileEntry(url: URL(fileURLWithPath: "/archive-root/a/b/c/d"), name: "d", isDirectory: true, isFromArchive: true, archiveRelativePath: "a/b/c/d", children: [leaf])
        let levelC = FileEntry(url: URL(fileURLWithPath: "/archive-root/a/b/c"), name: "c", isDirectory: true, isFromArchive: true, archiveRelativePath: "a/b/c", children: [levelD])
        let levelB = FileEntry(url: URL(fileURLWithPath: "/archive-root/a/b"), name: "b", isDirectory: true, isFromArchive: true, archiveRelativePath: "a/b", children: [levelC, sibling])
        let levelA = FileEntry(url: URL(fileURLWithPath: "/archive-root/a"), name: "a", isDirectory: true, isFromArchive: true, archiveRelativePath: "a", children: [levelB])

        let appState = AppState()
        appState.mode = .browseArchive
        appState.setEntries([levelA])

        let rootNode = try #require(appState.rootNodes.first)
        #expect(rootNode.size == 0)
        #expect(rootNode.archiveTotalSize == 500)
        #expect(rootNode.toFileEntry().children == nil)

        let leafNode = try #require(appState.node(for: leaf.id))
        let siblingNode = try #require(appState.node(for: sibling.id))
        let levelCNode = try #require(appState.node(for: levelC.id))
        #expect(leafNode.parent?.parent === levelCNode)

        // Cached archiveTotalSize stays consistent if a descendant's size changes
        leafNode.size = 500
        #expect(rootNode.archiveTotalSize == 580)
        #expect(rootNode.size == 0)

        // Select nodes across depths 0, 2, and 4 while remaining at root level
        appState.selectedEntryIDs = [rootNode.id, siblingNode.id, leafNode.id]
        let selected = appState.selectedNodes
        #expect(selected.count == 3)
        #expect(selected.contains(where: { $0 === rootNode }))
        #expect(selected.contains(where: { $0 === siblingNode }))
        #expect(selected.contains(where: { $0 === leafNode }))
    }

    @Test func multiWindowIsolation_independentAppStatesSharingPreferencesManager() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folderA = dir.appendingPathComponent("Alpha")
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        let fileA = folderA.appendingPathComponent("alpha.txt")
        try Data(repeating: 0x61, count: 64).write(to: fileA)

        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        let sharedPreferences = PreferencesManager()
        sharedPreferences.configure(with: container.mainContext)

        let windowA = AppState()
        let windowB = AppState()
        windowA.preferencesManager = sharedPreferences
        windowB.preferencesManager = sharedPreferences

        // Window A enters compress mode, navigates into Alpha, and selects alpha.txt
        await windowA.loadFilesAsync(from: [folderA])
        let alphaNode = try #require(windowA.rootNodes.first)
        await windowA.navigateIntoAsync(alphaNode)
        windowA.selectAll()

        // Window B independently enters browseArchive mode with different entries & selection
        let archiveEntry = FileEntry(
            url: URL(fileURLWithPath: "/archive-root/beta.bin"),
            name: "beta.bin",
            size: 1024,
            isFromArchive: true,
            archiveRelativePath: "beta.bin"
        )
        windowB.mode = .browseArchive
        windowB.sourceArchiveURL = URL(fileURLWithPath: "/tmp/beta.zip")
        windowB.setEntries([archiveEntry])
        windowB.selectedEntryIDs = [archiveEntry.id]

        // Verify strict per-window isolation
        #expect(windowA.mode == .compress)
        #expect(windowB.mode == .browseArchive)
        #expect(windowA.rootNodes.map(\.name) == ["Alpha"])
        #expect(windowB.rootNodes.map(\.name) == ["beta.bin"])
        #expect(windowA.navigationNodeIDs == [alphaNode.id])
        #expect(windowB.navigationNodeIDs.isEmpty)
        #expect(windowA.selectedNodes.map(\.name) == ["alpha.txt"])
        #expect(windowB.selectedNodes.map(\.name) == ["beta.bin"])
        #expect(windowA.node(for: archiveEntry.id) == nil)
        #expect(windowB.node(for: alphaNode.id) == nil)

        // Updating shared preferences does not disturb either active window's tree or selection
        sharedPreferences.updatePreferences { prefs in
            prefs.revealInFinderAfterExtract = false
        }
        #expect(!windowA.revealInFinderAfterExtract)
        #expect(!windowB.revealInFinderAfterExtract)
        #expect(windowA.mode == .compress)
        #expect(windowB.mode == .browseArchive)
        #expect(windowA.navigationNodeIDs == [alphaNode.id])
        #expect(windowB.selectedNodes.count == 1)
    }

    @Test func navigateInto_returnsImmediatelyWithoutBlockingAndPopulatesChildrenAsync() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("LazyFolder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "alpha".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let appState = AppState()
        await appState.loadFilesAsync(from: [folder])

        let folderNode = try #require(appState.rootNodes.first)
        #expect(!folderNode.hasLoadedChildren)

        // Synchronous navigateInto pushes navigation immediately without blocking on disk I/O
        let revisionBefore = appState.nodeUpdateRevision
        appState.navigateInto(folderNode)
        #expect(appState.canNavigateUp)
        #expect(appState.navigationNodeIDs == [folderNode.id])
        #expect(!folderNode.hasLoadedChildren)

        // Children populate asynchronously and emit a reloadChildren node update for the navigated node
        for _ in 0..<100 {
            if folderNode.hasLoadedChildren { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(folderNode.hasLoadedChildren)
        #expect(appState.displayedNodes.map(\.name) == ["a.txt", "b.txt"])
        #expect(appState.nodeUpdateRevision > revisionBefore)
        #expect(appState.lastUpdatedNodeID == folderNode.id)
        #expect(appState.lastUpdatedNodeReloadChildren)
    }

    @Test func addEntries_rapidSequentialDropsNeverDropURLsAndCoordinateSizing() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folder1 = dir.appendingPathComponent("Folder1")
        let folder2 = dir.appendingPathComponent("Folder2")
        let folder3 = dir.appendingPathComponent("Folder3")
        try fm.createDirectory(at: folder1, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder2, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder3, withIntermediateDirectories: true)

        try Data(repeating: 0x01, count: 100).write(to: folder1.appendingPathComponent("f1.bin"))
        try Data(repeating: 0x02, count: 200).write(to: folder2.appendingPathComponent("f2.bin"))
        try Data(repeating: 0x03, count: 300).write(to: folder3.appendingPathComponent("f3.bin"))

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        let fileC = dir.appendingPathComponent("c.txt")
        try Data(repeating: 0x41, count: 10).write(to: fileA)
        try Data(repeating: 0x42, count: 20).write(to: fileB)
        try Data(repeating: 0x43, count: 30).write(to: fileC)

        let appState = AppState()
        await appState.loadFilesAsync(from: [folder1])

        // Rapid sequential fire-and-forget drops (including a duplicate) must not cancel each other
        appState.addEntries(from: [fileA])
        appState.addEntries(from: [folder2])
        appState.addEntries(from: [fileB, folder3])
        appState.addEntries(from: [fileA])
        await appState.addEntriesAsync(from: [fileC])

        #expect(!appState.isLoading)
        #expect(Set(appState.rootNodes.map(\.name)) == ["Folder1", "Folder2", "Folder3", "a.txt", "b.txt", "c.txt"])
        #expect(appState.rootNodes.count == 6)
        #expect(appState.totalSize == 660)

        let folderSizes = Dictionary(uniqueKeysWithValues: appState.rootNodes.filter(\.isDirectory).map { ($0.name, $0.size) })
        #expect(folderSizes == ["Folder1": 100, "Folder2": 200, "Folder3": 300])
    }

    @Test func cancelBackgroundTasks_stopsInFlightWorkAndClearsLoadingState() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Pending")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 64).write(to: folder.appendingPathComponent("item.bin"))

        let appState = AppState()
        appState.loadFiles(from: [folder])
        appState.cancelBackgroundTasks()

        try await Task.sleep(for: .milliseconds(50))
        #expect(!appState.isLoading)
        #expect(!appState.isCalculatingSizes)
        #expect(appState.rootNodes.isEmpty)
        #expect(appState.mode == .empty)
    }

    @Test func removeSelectedEntries_removesTopLevelAndNestedNodesAndTracksExclusions() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let rootFolder = dir.appendingPathComponent("Project")
        let nestedDir = rootFolder.appendingPathComponent("Logs")
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let keepFile = rootFolder.appendingPathComponent("keep.txt")
        let dropFile = rootFolder.appendingPathComponent("drop.txt")
        let logFile = nestedDir.appendingPathComponent("debug.log")
        let extraRoot = dir.appendingPathComponent("standalone.txt")
        try Data(repeating: 0x41, count: 100).write(to: keepFile)
        try Data(repeating: 0x42, count: 250).write(to: dropFile)
        try Data(repeating: 0x43, count: 400).write(to: logFile)
        try Data(repeating: 0x44, count: 50).write(to: extraRoot)

        let appState = AppState()
        await appState.loadFilesAsync(from: [rootFolder, extraRoot])
        #expect(appState.totalSize == 800)

        let projectNode = try #require(appState.rootNodes.first(where: { $0.name == "Project" }))
        let standaloneNode = try #require(appState.rootNodes.first(where: { $0.name == "standalone.txt" }))
        await appState.loadChildrenIfNeededAsync(for: projectNode)

        let dropNode = try #require(projectNode.children?.first(where: { $0.name == "drop.txt" }))
        let logsNode = try #require(projectNode.children?.first(where: { $0.name == "Logs" }))

        // Removing a nested file updates children, records archive-relative exclusion, and deducts bytes
        appState.selectedEntryIDs = [dropNode.id]
        appState.removeSelectedEntries()
        #expect(appState.selectedEntryIDs.isEmpty)
        #expect(projectNode.children?.map(\.name) == ["Logs", "keep.txt"])
        #expect(appState.excludedCompressRelativePaths.contains("Project/drop.txt"))
        #expect(appState.totalSize == 550)

        // Removing a nested folder records exclusion and recalculates root folder size asynchronously
        appState.selectedEntryIDs = [logsNode.id]
        appState.removeSelectedEntries()
        #expect(projectNode.children?.map(\.name) == ["keep.txt"])
        #expect(appState.excludedCompressRelativePaths.contains("Project/Logs"))
        for _ in 0..<100 {
            if !appState.isCalculatingSizes && appState.totalSize == 150 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(appState.totalSize == 150)

        // Removing a top-level file removes it from rootNodes cleanly
        appState.selectedEntryIDs = [standaloneNode.id]
        appState.removeSelectedEntries()
        #expect(appState.rootNodes.map(\.name) == ["Project"])
        #expect(appState.totalSize == 100)
    }
}
