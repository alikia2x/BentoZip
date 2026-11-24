import Foundation

extension AppState {

    // MARK: - Preferences

    public func applyPreferences() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
    }

    /// Persist current compression settings and behavior toggles to `AppPreferences`.
    public func savePreferences() {
        preferencesManager?.updatePreferences { prefs in
            prefs.defaultFormat = compressionSettings.format.rawValue
            prefs.defaultCompressionLevel = compressionSettings.compressionLevel.rawValue
            prefs.exclusionPatterns = compressionSettings.exclusionPatterns
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
        }
    }

    func handlePreferencesDidChange() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        if mode == .empty {
            preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
        }
        refreshRecentArchives()
    }

    // MARK: - Recent Archives

    /// Revalidate `recentArchives` asynchronously off the main actor.
    public func refreshRecentArchives() {
        recentValidationTask?.cancel()
        guard let manager = preferencesManager else {
            recentArchiveItems = []
            return
        }
        let rawPaths = manager.loadPreferences().recentArchives
        recentValidationTask = Task { [weak self] in
            await self?.validateAndSetRecentArchives(rawPaths)
        }
    }

    /// Async variant of `refreshRecentArchives()` suitable for awaiting in tests.
    public func refreshRecentArchivesAsync() async {
        recentValidationTask?.cancel()
        guard let manager = preferencesManager else {
            recentArchiveItems = []
            return
        }
        let rawPaths = manager.loadPreferences().recentArchives
        await validateAndSetRecentArchives(rawPaths)
    }

    private func validateAndSetRecentArchives(_ rawPaths: [String]) async {
        let validated = await Task.detached(priority: .utility) {
            var items: [RecentArchiveItem] = []
            items.reserveCapacity(rawPaths.count)
            for path in rawPaths {
                if Task.isCancelled { return items }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path),
                   FormatDetector.isArchiveFile(url) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                    let size = values?.fileSize.map(Int64.init)
                    items.append(RecentArchiveItem(url: url, fileSize: size))
                }
            }
            return items
        }.value
        guard !Task.isCancelled else { return }
        recentArchiveItems = validated
    }

    // MARK: - Archive Naming Helpers

    /// Return the archive name with its extension synchronized from `oldFormat` to `newFormat`.
    public func archiveNameWithSyncedExtension(oldFormat: ArchiveFormat, newFormat: ArchiveFormat) -> String {
        CompressionSettings.archiveNameWithSyncedExtension(
            compressionSettings.archiveName,
            oldFormat: oldFormat,
            newFormat: newFormat
        )
    }

    /// Switch `compressionSettings.format` and synchronize `compressionSettings.archiveName` extension.
    public func updateCompressionFormat(to newFormat: ArchiveFormat) {
        compressionSettings = compressionSettings.updatingFormat(to: newFormat)
    }

    /// Compute default archive filename stem (without extension) for local URLs.
    /// Directories preserve dots in their name (e.g. `Project.v1.0`).
    public nonisolated static func defaultArchiveStem(for urls: [URL]) -> String {
        guard urls.count == 1, let first = urls.first else {
            return "archive"
        }
        if FileUtils.isDirectory(at: first) {
            return first.lastPathComponent
        }
        let stem = first.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? first.lastPathComponent : stem
    }
}
