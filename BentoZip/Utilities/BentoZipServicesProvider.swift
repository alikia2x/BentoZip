import AppKit
import BentoZipCore
import SwiftData

/// Handles macOS Services menu invocations (`NSServices` in `Info.plist`) from Finder and other apps.
@MainActor
final class BentoZipServicesProvider: NSObject {
    static let shared = BentoZipServicesProvider()

    private override init() {
        super.init()
    }

    @objc func compressWithBentoZip(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = extractFileURLs(from: pboard), !urls.isEmpty else {
            error.pointee = String(localized: "No files or folders were provided to compress.") as NSString
            return
        }
        DocumentWindowRouter.shared.openFilesToCompress(urls)
    }

    @objc func extractHereWithBentoZip(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = extractFileURLs(from: pboard), !urls.isEmpty else {
            error.pointee = String(localized: "No archive files were provided to extract.") as NSString
            return
        }

        extractArchivesHere(urls)
    }

    func extractArchivesHere(_ urls: [URL]) {
        Task { @MainActor in
            let archives = await filterArchiveURLs(urls)
            guard !archives.isEmpty else { return }

            let overrideManager = makeOverridePreferencesManager(
                mode: .sameFolder,
                customDirectory: nil
            )
            await CompressionCoordinator().extractMultipleDirectly(
                archiveURLs: archives,
                preferencesManager: overrideManager
            ) { encryptedURL in
                DocumentWindowRouter.shared.openArchive(encryptedURL)
            }
        }
    }

    @objc func extractToFolderWithBentoZip(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = extractFileURLs(from: pboard), !urls.isEmpty else {
            error.pointee = String(localized: "No archive files were provided to extract.") as NSString
            return
        }

        Task { @MainActor in
            let archives = await filterArchiveURLs(urls)
            guard !archives.isEmpty else { return }

            NSApplication.shared.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Extract Here")
            panel.message = String(localized: "Choose a destination folder for extraction.")
            guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

            let overrideManager = makeOverridePreferencesManager(
                mode: .customFolder,
                customDirectory: destinationFolder.path
            )
            await CompressionCoordinator().extractMultipleDirectly(
                archiveURLs: archives,
                preferencesManager: overrideManager
            ) { encryptedURL in
                DocumentWindowRouter.shared.openArchive(encryptedURL)
            }
        }
    }

    @objc func browseWithBentoZip(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = extractFileURLs(from: pboard), !urls.isEmpty else {
            error.pointee = String(localized: "No archive files were provided to browse.") as NSString
            return
        }

        Task { @MainActor in
            let archives = await filterArchiveURLs(urls)
            let targets = archives.isEmpty ? urls : archives
            for url in targets {
                DocumentWindowRouter.shared.openArchive(url)
            }
        }
    }

    // MARK: - Helpers

    private func extractFileURLs(from pboard: NSPasteboard) -> [URL]? {
        if let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }

        let legacyType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pboard.propertyList(forType: legacyType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return nil
    }

    private func filterArchiveURLs(_ urls: [URL]) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            urls.filter { FormatDetector.isArchiveFile($0) }
        }.value
    }

    private func makeOverridePreferencesManager(
        mode: ExtractDestinationMode,
        customDirectory: String?
    ) -> PreferencesManager? {
        let baseManager = DocumentWindowRouter.shared.preferencesManager
        let basePrefs = baseManager?.loadPreferences() ?? AppPreferences()

        guard let container = try? ModelContainer(
            for: AppPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) else {
            return baseManager
        }

        let context = ModelContext(container)
        let copy = AppPreferences(
            defaultFormat: basePrefs.defaultFormat,
            defaultCompressionLevel: basePrefs.defaultCompressionLevel,
            exclusionPatterns: basePrefs.exclusionPatterns,
            lastSaveDirectory: basePrefs.lastSaveDirectory,
            recentArchives: basePrefs.recentArchives,
            revealInFinderAfterExtract: basePrefs.revealInFinderAfterExtract,
            unwrapSingleTopDirectory: basePrefs.unwrapSingleTopDirectory,
            maxCacheSizeMB: basePrefs.maxCacheSizeMB,
            archiveOpenAction: basePrefs.archiveOpenAction,
            extractDestinationMode: mode.rawValue,
            customExtractDirectory: customDirectory,
            extractConflictPolicy: basePrefs.extractConflictPolicy,
            moveArchiveToTrashAfterExtract: basePrefs.moveArchiveToTrashAfterExtract,
            closeWindowAfterExtract: basePrefs.closeWindowAfterExtract,
            showHiddenFiles: basePrefs.showHiddenFiles,
            sortColumnKey: basePrefs.sortColumnKey,
            sortAscending: basePrefs.sortAscending,
            stripQuarantineOnExtract: basePrefs.stripQuarantineOnExtract,
            savedPresetsJSON: basePrefs.savedPresetsJSON,
            autoTryVaultPasswords: basePrefs.autoTryVaultPasswords,
            defaultViewMode: basePrefs.defaultViewMode
        )
        context.insert(copy)
        try? context.save()

        let manager = PreferencesManager()
        manager.configure(with: context)
        return manager
    }
}
