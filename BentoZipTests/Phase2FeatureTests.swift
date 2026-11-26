import Foundation
import SwiftData
import Testing
@testable import BentoZipCore

// MARK: - Presets, Browser View Mode & Gallery Tests

@Suite(.serialized) @MainActor
struct Phase2PresetsAndStateTests {
    private func makeInMemoryPreferencesManager() throws -> PreferencesManager {
        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let manager = PreferencesManager()
        manager.configure(with: container.mainContext)
        return manager
    }

    @Test func archivePreset_codableRoundTrip_builtInDefaults_andSettingsInit() throws {
        let defaults = ArchivePreset.builtInDefaults
        #expect(defaults.count == 2)
        #expect(defaults[0].name == "Clean ZIP")
        #expect(defaults[0].format == .zip)
        #expect(defaults[1].name == "Encrypted 7z (500 MB Split)")
        #expect(defaults[1].format == .sevenZip)
        #expect(defaults[1].volumeSizeBytes == 500 * 1024 * 1024)

        let settings = CompressionSettings(
            format: .sevenZip,
            compressionLevel: .best,
            archiveName: "backup.7z",
            preserveDirectoryStructure: false,
            exclusionPatterns: [".git", "*.log"],
            password: "ignored-by-preset",
            zipEncryptionMethod: .zipCrypto,
            volumeSizeBytes: 64 * 1024 * 1024,
            encryptHeaders: false,
            followSymlinks: true,
            compressEachSeparately: true
        )

        let preset = ArchivePreset(name: "Custom 7z", settings: settings)
        #expect(preset.name == "Custom 7z")
        #expect(preset.format == .sevenZip)
        #expect(preset.compressionLevel == .best)
        #expect(preset.zipEncryptionMethod == .zipCrypto)
        #expect(!preset.encryptHeaders)
        #expect(preset.volumeSizeBytes == 64 * 1024 * 1024)
        #expect(!preset.preserveDirectoryStructure)
        #expect(preset.followSymlinks)
        #expect(preset.compressEachSeparately)
        #expect(preset.exclusionPatterns == [".git", "*.log"])

        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ArchivePreset.self, from: encoded)
        #expect(decoded == preset)
    }

    @Test func preferencesManager_presetCRUD_persistsAddUpdateAndDelete() throws {
        let manager = try makeInMemoryPreferencesManager()

        // Initially falls back to built-in defaults
        #expect(manager.loadPresets() == ArchivePreset.builtInDefaults)

        // Add new preset
        let custom = ArchivePreset(
            name: "Batch TAR.GZ",
            format: .tarGz,
            compressionLevel: .fast,
            compressEachSeparately: true,
            exclusionPatterns: ["*.tmp"]
        )
        manager.addPreset(custom)
        let afterAdd = manager.loadPresets()
        #expect(afterAdd.count == 3)
        #expect(afterAdd.last == custom)

        // Update existing preset by matching ID
        var updated = custom
        updated.name = "Batch TAR.GZ Updated"
        updated.followSymlinks = true
        manager.addPreset(updated)
        let afterUpdate = manager.loadPresets()
        #expect(afterUpdate.count == 3)
        #expect(afterUpdate.last == updated)

        // Delete preset
        manager.deletePreset(id: custom.id)
        let afterDelete = manager.loadPresets()
        #expect(afterDelete == ArchivePreset.builtInDefaults)

        // Explicit savePresets replaces entire list
        manager.savePresets([updated])
        #expect(manager.loadPresets() == [updated])
    }

    @Test func appState_applyPreset_updatesAllCompressionSettingsAndSyncsExtension() {
        let appState = AppState()
        appState.compressionSettings.format = .zip
        appState.compressionSettings.archiveName = "release.zip"

        let preset7z = ArchivePreset(
            name: "Split 7z",
            format: .sevenZip,
            compressionLevel: .best,
            zipEncryptionMethod: .zipCrypto,
            encryptHeaders: false,
            volumeSizeBytes: 10 * 1024 * 1024,
            preserveDirectoryStructure: false,
            followSymlinks: true,
            compressEachSeparately: true,
            exclusionPatterns: [".DS_Store", "node_modules"]
        )

        appState.applyPreset(preset7z)
        #expect(appState.compressionSettings.format == .sevenZip)
        #expect(appState.compressionSettings.archiveName == "release.7z")
        #expect(appState.compressionSettings.compressionLevel == .best)
        #expect(appState.compressionSettings.zipEncryptionMethod == .zipCrypto)
        #expect(!appState.compressionSettings.encryptHeaders)
        #expect(appState.compressionSettings.volumeSizeBytes == 10 * 1024 * 1024)
        #expect(!appState.compressionSettings.preserveDirectoryStructure)
        #expect(appState.compressionSettings.followSymlinks)
        #expect(appState.compressionSettings.compressEachSeparately)
        #expect(appState.compressionSettings.exclusionPatterns == [".DS_Store", "node_modules"])

        // Applying a non-split format clamps volumeSizeBytes to 0
        let presetTar = ArchivePreset(
            name: "Plain TAR",
            format: .tar,
            compressionLevel: .none,
            volumeSizeBytes: 1024 * 1024,
            followSymlinks: false,
            compressEachSeparately: false
        )
        appState.applyPreset(presetTar)
        #expect(appState.compressionSettings.format == .tar)
        #expect(appState.compressionSettings.archiveName == "release.tar")
        #expect(appState.compressionSettings.volumeSizeBytes == 0)
        #expect(!appState.compressionSettings.followSymlinks)
        #expect(!appState.compressionSettings.compressEachSeparately)
    }

    @Test func browserViewMode_persistsAndSyncsViaPreferencesManager() throws {
        let manager = try makeInMemoryPreferencesManager()
        let appState = AppState()
        appState.preferencesManager = manager
        #expect(appState.viewMode == .list)

        appState.viewMode = .grid
        appState.savePreferences()

        #expect(manager.loadPreferences().defaultViewMode == BrowserViewMode.grid.rawValue)

        let reloaded = AppState()
        reloaded.preferencesManager = manager
        #expect(reloaded.viewMode == .grid)
    }

    @Test func galleryImageNodes_filtersCurrentFolderOrComicArchiveInNaturalOrder() {
        let appState = AppState()
        appState.mode = .browseArchive
        appState.sourceArchiveURL = URL(fileURLWithPath: "/tmp/album.zip")

        let entries = ArchiveTreeBuilder.buildTree(from: [
            ArchiveTreeBuilder.FlatEntry(path: "page10.png", name: "page10.png", isDirectory: false, size: 100),
            ArchiveTreeBuilder.FlatEntry(path: "page2.jpg", name: "page2.jpg", isDirectory: false, size: 100),
            ArchiveTreeBuilder.FlatEntry(path: ".hidden.png", name: ".hidden.png", isDirectory: false, size: 50),
            ArchiveTreeBuilder.FlatEntry(path: "notes.txt", name: "notes.txt", isDirectory: false, size: 20),
            ArchiveTreeBuilder.FlatEntry(path: "chapter1/01.webp", name: "01.webp", isDirectory: false, size: 80),
            ArchiveTreeBuilder.FlatEntry(path: "chapter2/02.png", name: "02.png", isDirectory: false, size: 80)
        ], unwrapSingleTopDirectory: false)
        appState.setEntries(entries)

        // Regular .zip only lists images in the current folder (natural sort: page2 < page10), hiding dotfiles
        #expect(appState.galleryImageNodes.map(\.name) == ["page2.jpg", "page10.png"])

        appState.showHiddenFiles = true
        #expect(appState.galleryImageNodes.map(\.name) == [".hidden.png", "page2.jpg", "page10.png"])
        appState.showHiddenFiles = false

        // Comic archive (.cbz / .cbr) flattens images recursively across all subfolders
        appState.sourceArchiveURL = URL(fileURLWithPath: "/tmp/issue1.cbz")
        #expect(
            appState.galleryImageNodes.compactMap(\.archiveRelativePath) == [
                "chapter1/01.webp",
                "chapter2/02.png",
                "page2.jpg",
                "page10.png"
            ]
        )

        appState.sourceArchiveURL = URL(fileURLWithPath: "/tmp/issue1.cbr")
        #expect(appState.galleryImageNodes.count == 4)

        // Active search query narrows gallery images across the tree
        appState.searchQuery = "chapter"
        #expect(appState.galleryImageNodes.compactMap(\.archiveRelativePath) == [
            "chapter1/01.webp",
            "chapter2/02.png"
        ])
    }
}

// MARK: - Password Vault & Generator Tests

@Suite(.serialized)
struct Phase2PasswordVaultTests {
    @Test func passwordVaultService_inMemoryCRUDDeduplicationAndContains() {
        let vault = PasswordVaultService.inMemory()
        #expect(vault.loadEntries().isEmpty)
        #expect(vault.allPasswords().isEmpty)
        #expect(!vault.contains(password: ""))
        #expect(!vault.contains(password: "secret"))

        let first = vault.addEntry(label: "  Work Archive  ", password: "alpha-password")
        let duplicate = vault.addEntry(label: "   ", password: "alpha-password")
        let emptyPassword = vault.addEntry(label: "Empty", password: "")
        let second = vault.addEntry(label: "Personal", password: "beta-password")

        #expect(first.label == "Work Archive")
        #expect(duplicate.label == "Untitled")
        #expect(vault.loadEntries().count == 4)
        // Deduplicated and omits empty passwords while preserving insertion order
        #expect(vault.allPasswords() == ["alpha-password", "beta-password"])
        #expect(vault.contains(password: "alpha-password"))
        #expect(vault.contains(password: "beta-password"))
        #expect(!vault.contains(password: ""))

        vault.deleteEntry(id: first.id)
        #expect(vault.contains(password: "alpha-password")) // duplicate still present
        vault.deleteEntry(id: duplicate.id)
        #expect(!vault.contains(password: "alpha-password"))
        #expect(vault.allPasswords() == ["beta-password"])

        vault.deleteEntry(id: emptyPassword.id)
        vault.deleteEntry(id: second.id)
        #expect(vault.loadEntries().isEmpty)
    }

    @Test func passwordGenerator_honorsLengthAndCharacterClasses() {
        #expect(PasswordGenerator.generate(length: 0, includeSymbols: true).isEmpty)
        #expect(PasswordGenerator.generate(length: -5, includeSymbols: false).isEmpty)

        let short = PasswordGenerator.generate(length: 2, includeSymbols: true)
        #expect(short.count == 2)

        let symbolSet = CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{}|;:,.<>?")
        let withSymbols = PasswordGenerator.generate(length: 24, includeSymbols: true)
        #expect(withSymbols.count == 24)
        #expect(withSymbols.rangeOfCharacter(from: .lowercaseLetters) != nil)
        #expect(withSymbols.rangeOfCharacter(from: .uppercaseLetters) != nil)
        #expect(withSymbols.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(withSymbols.rangeOfCharacter(from: symbolSet) != nil)

        let withoutSymbols = PasswordGenerator.generate(length: 24, includeSymbols: false)
        #expect(withoutSymbols.count == 24)
        #expect(withoutSymbols.rangeOfCharacter(from: .lowercaseLetters) != nil)
        #expect(withoutSymbols.rangeOfCharacter(from: .uppercaseLetters) != nil)
        #expect(withoutSymbols.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(withoutSymbols.rangeOfCharacter(from: symbolSet) == nil)
    }
}

// MARK: - Inline Preview Helper Tests

@Suite(.serialized)
struct Phase2InlinePreviewTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("InlinePreviewTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func isImageFile_andIsTextPreviewable_detectExpectedExtensionsAndBaseNames() {
        #expect(InlinePreviewHelper.isImageFile("cover.png"))
        #expect(InlinePreviewHelper.isImageFile("PHOTO.WEBP"))
        #expect(InlinePreviewHelper.isImageFile(URL(fileURLWithPath: "/tmp/shot.heic")))
        #expect(!InlinePreviewHelper.isImageFile("readme.txt"))
        #expect(!InlinePreviewHelper.isImageFile("README"))

        #expect(InlinePreviewHelper.isTextPreviewable("App.swift"))
        #expect(InlinePreviewHelper.isTextPreviewable("config.YAML"))
        #expect(InlinePreviewHelper.isTextPreviewable("README"))
        #expect(InlinePreviewHelper.isTextPreviewable("Makefile"))
        #expect(InlinePreviewHelper.isTextPreviewable("Dockerfile"))
        #expect(InlinePreviewHelper.isTextPreviewable(URL(fileURLWithPath: "/tmp/.gitignore")))
        #expect(!InlinePreviewHelper.isTextPreviewable("archive.zip"))
        #expect(!InlinePreviewHelper.isTextPreviewable("photo.png"))
        #expect(!InlinePreviewHelper.isTextPreviewable("app.bin"))
    }

    @Test func loadTextSnippet_handlesUTF8_UTF16BOM_binaryRejection_andTruncation() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // 1. UTF-8 text
        let utf8URL = dir.appendingPathComponent("note.txt")
        try "Hello BentoZip 🚀".write(to: utf8URL, atomically: true, encoding: .utf8)
        let utf8Snippet = await InlinePreviewHelper.loadTextSnippet(from: utf8URL)
        #expect(utf8Snippet == "Hello BentoZip 🚀")

        // 2. UTF-16LE with BOM (contains NUL bytes in ASCII characters, must still decode!)
        let utf16URL = dir.appendingPathComponent("utf16.txt")
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append("Hi".data(using: .utf16LittleEndian)!)
        try utf16Data.write(to: utf16URL)
        let utf16Snippet = await InlinePreviewHelper.loadTextSnippet(from: utf16URL)
        #expect(utf16Snippet == "Hi")

        // 3. Binary file with NUL bytes rejected (returns nil)
        let binURL = dir.appendingPathComponent("binary.dat")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: binURL)
        let binSnippet = await InlinePreviewHelper.loadTextSnippet(from: binURL)
        #expect(binSnippet == nil)

        // 4. Truncation mid-multibyte UTF-8 sequence trims trailing incomplete bytes cleanly
        let multiByteURL = dir.appendingPathComponent("multibyte.txt")
        try Data("AB🎉CD".utf8).write(to: multiByteURL) // "AB" (2 bytes) + "🎉" (4 bytes) + "CD" (2 bytes)
        let truncated = await InlinePreviewHelper.loadTextSnippet(from: multiByteURL, maxBytes: 4)
        #expect(truncated == "AB")
    }
}

// MARK: - Batch Operations & Silent Vault Auto-Unlock Tests

@Suite(.serialized) @MainActor
struct Phase2BatchAndVaultCoordinatorTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("Phase2CoordTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeInMemoryPreferencesManager() throws -> PreferencesManager {
        let schema = Schema([AppPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let manager = PreferencesManager()
        manager.configure(with: container.mainContext)
        return manager
    }

    @Test func compress_compressEachSeparately_createsIndividualArchivesPerInput() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("alpha.txt")
        let folderB = dir.appendingPathComponent("FolderB")
        try fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        try "alpha-payload".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta-payload".write(to: folderB.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let coordinator = CompressionCoordinator(engine: engine)
        let appState = AppState()
        appState.coordinator = coordinator
        appState.revealInFinderAfterExtract = false

        await appState.loadFilesAsync(from: [fileA, folderB])
        appState.compressionSettings.format = .zip
        appState.compressionSettings.compressEachSeparately = true

        let progressState = ProgressState()
        await coordinator.compress(appState: appState, progressState: progressState)

        #expect(appState.lastError == nil)
        #expect(!progressState.isOperationInProgress)

        let archiveA = dir.appendingPathComponent("alpha.zip")
        let archiveB = dir.appendingPathComponent("FolderB.zip")
        #expect(fm.fileExists(atPath: archiveA.path))
        #expect(fm.fileExists(atPath: archiveB.path))

        let entriesA = try await engine.listEntries(in: archiveA)
        let entriesB = try await engine.listEntries(in: archiveB)
        #expect(entriesA.map(\.name) == ["alpha.txt"])
        #expect(entriesB.map(\.name) == ["beta.txt"])
    }

    @Test func extractMultipleDirectly_extractsBatchArchivesAndRecordsRecents() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcOne = dir.appendingPathComponent("one.txt")
        let srcTwo = dir.appendingPathComponent("two.txt")
        try "content-one".write(to: srcOne, atomically: true, encoding: .utf8)
        try "content-two".write(to: srcTwo, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveOne = dir.appendingPathComponent("batch_one.zip")
        let archiveTwo = dir.appendingPathComponent("batch_two.zip")
        try await engine.create(from: [srcOne], to: archiveOne, settings: CompressionSettings(format: .zip)) { _ in }
        try await engine.create(from: [srcTwo], to: archiveTwo, settings: CompressionSettings(format: .zip)) { _ in }

        let outRoot = dir.appendingPathComponent("BatchOut")
        let manager = try makeInMemoryPreferencesManager()
        manager.updatePreferences { prefs in
            prefs.extractDestinationMode = ExtractDestinationMode.customFolder.rawValue
            prefs.customExtractDirectory = outRoot.path
            prefs.extractConflictPolicy = ExtractConflictPolicy.overwrite.rawValue
            prefs.revealInFinderAfterExtract = false
        }

        let coordinator = CompressionCoordinator(engine: engine)
        await coordinator.extractMultipleDirectly(
            archiveURLs: [archiveOne, archiveTwo],
            preferencesManager: manager
        )

        #expect(try String(contentsOf: outRoot.appendingPathComponent("batch_one/one.txt"), encoding: .utf8) == "content-one")
        #expect(try String(contentsOf: outRoot.appendingPathComponent("batch_two/two.txt"), encoding: .utf8) == "content-two")
        let recents = manager.loadPreferences().recentArchives
        #expect(recents.contains(archiveOne.path))
        #expect(recents.contains(archiveTwo.path))
    }

    @Test func vaultAutoUnlock_silentlyUnlocksBrowseExtractAndDirectExtract() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let secretFile = dir.appendingPathComponent("vaulted.txt")
        try "vault-unlocked-payload".write(to: secretFile, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()

        // Encrypted-header 7z archive (triggers passwordRequired on listArchive)
        let sevenZURL = dir.appendingPathComponent("locked_headers.7z")
        try await engine.create(
            from: [secretFile],
            to: sevenZURL,
            settings: CompressionSettings(format: .sevenZip, password: "vault-secret", encryptHeaders: true)
        ) { _ in }

        // Open-header encrypted ZIP archive (lists without password, triggers passwordRequired on extract)
        let zipURL = dir.appendingPathComponent("locked_body.zip")
        try await engine.create(
            from: [secretFile],
            to: zipURL,
            settings: CompressionSettings(format: .zip, password: "vault-secret")
        ) { _ in }

        let vault = PasswordVaultService.inMemory([
            PasswordVaultEntry(label: "Wrong", password: "wrong-candidate"),
            PasswordVaultEntry(label: "Match", password: "vault-secret")
        ])

        // 1. browseArchive silently unlocks encrypted-header 7z when autoTryVaultPasswords == true
        let coordinator = CompressionCoordinator(engine: engine, passwordVault: vault)
        let browseState = AppState()
        browseState.coordinator = coordinator
        browseState.autoTryVaultPasswords = true

        await coordinator.browseArchive(at: sevenZURL, appState: browseState)
        #expect(!browseState.needsPasswordPrompt)
        #expect(browseState.archivePassword == "vault-secret")
        #expect(browseState.fileEntries.map(\.name) == ["vaulted.txt"])

        // When autoTryVaultPasswords == false, browseArchive must prompt instead of using vault
        let manualState = AppState()
        manualState.coordinator = coordinator
        manualState.autoTryVaultPasswords = false
        await coordinator.browseArchive(at: sevenZURL, appState: manualState)
        #expect(manualState.needsPasswordPrompt)
        #expect(manualState.archivePassword == nil)

        // 2. extract silently unlocks open-header encrypted ZIP
        let extractState = AppState()
        extractState.coordinator = coordinator
        extractState.revealInFinderAfterExtract = false
        extractState.autoTryVaultPasswords = true
        await coordinator.browseArchive(at: zipURL, appState: extractState)
        #expect(extractState.archivePassword == nil)

        let progressState = ProgressState()
        await coordinator.extract(appState: extractState, progressState: progressState)
        #expect(!extractState.needsPasswordPrompt)
        #expect(extractState.archivePassword == "vault-secret")
        let extractedZipFile = dir.appendingPathComponent("locked_body/vaulted.txt")
        #expect(try String(contentsOf: extractedZipFile, encoding: .utf8) == "vault-unlocked-payload")

        // 3. extractDirectly silently unlocks encrypted 7z without invoking password fallback
        let manager = try makeInMemoryPreferencesManager()
        manager.updatePreferences { prefs in
            prefs.autoTryVaultPasswords = true
            prefs.revealInFinderAfterExtract = false
            prefs.extractConflictPolicy = ExtractConflictPolicy.overwrite.rawValue
        }
        var fallbackCalled = false
        await coordinator.extractDirectly(
            archiveURL: sevenZURL,
            preferencesManager: manager,
            onNeedPasswordFallback: { _ in fallbackCalled = true }
        )
        #expect(!fallbackCalled)
        let extracted7zFile = dir.appendingPathComponent("locked_headers/vaulted.txt")
        #expect(try String(contentsOf: extracted7zFile, encoding: .utf8) == "vault-unlocked-payload")
    }
}
