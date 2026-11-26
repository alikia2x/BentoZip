import Foundation
import SwiftData

@MainActor
public final class PreferencesManager {
    /// Posted whenever persisted preferences are saved so all windows and view models stay synchronized.
    public static let preferencesDidChangeNotification = Notification.Name("BentoZipPreferencesDidChange")

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    public init() {}

    public func configure(with context: ModelContext) {
        self.modelContext = context
        self.modelContainer = context.container
        let prefs = ensureDefaultPreferences()
        ArchiveCacheManager.shared.setMaxCacheSizeMB(prefs.maxCacheSizeMB)
    }

    @discardableResult
    public func ensureDefaultPreferences() -> AppPreferences {
        loadPreferences()
    }

    public func loadPreferences() -> AppPreferences {
        guard let context = modelContext else {
            return AppPreferences()
        }
        let descriptor = FetchDescriptor<AppPreferences>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let prefs = AppPreferences()
        context.insert(prefs)
        try? context.save()
        return prefs
    }

    public func savePreferences(_ prefs: AppPreferences) {
        try? modelContext?.save()
        ArchiveCacheManager.shared.setMaxCacheSizeMB(prefs.maxCacheSizeMB)
        NotificationCenter.default.post(name: Self.preferencesDidChangeNotification, object: nil)
    }

    public func updatePreferences(_ update: (AppPreferences) -> Void) {
        let prefs = loadPreferences()
        update(prefs)
        savePreferences(prefs)
    }

    public func applyDefaults(to settings: inout CompressionSettings, from prefs: AppPreferences) {
        if let format = ArchiveFormat.fromPersistedValue(prefs.defaultFormat) {
            settings.format = format
        }
        if let level = CompressionLevel(rawValue: prefs.defaultCompressionLevel) {
            settings.compressionLevel = level
        }
        settings.exclusionPatterns = prefs.exclusionPatterns
    }

    public func recordArchive(_ path: String, in prefs: AppPreferences) {
        var recent = prefs.recentArchives
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 10 {
            recent = Array(recent.prefix(10))
        }
        prefs.recentArchives = recent
        savePreferences(prefs)
    }

    public func recordArchive(_ path: String) {
        let prefs = loadPreferences()
        recordArchive(path, in: prefs)
    }

    // MARK: - Presets

    public func loadPresets() -> [ArchivePreset] {
        let json = loadPreferences().savedPresetsJSON
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ArchivePreset].self, from: data) else {
            return ArchivePreset.builtInDefaults
        }
        return decoded
    }

    public func savePresets(_ presets: [ArchivePreset]) {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        updatePreferences { prefs in
            prefs.savedPresetsJSON = json
        }
    }

    public func addPreset(_ preset: ArchivePreset) {
        var presets = loadPresets()
        if let existingIndex = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[existingIndex] = preset
        } else {
            presets.append(preset)
        }
        savePresets(presets)
    }

    public func deletePreset(id: UUID) {
        var presets = loadPresets()
        presets.removeAll { $0.id == id }
        savePresets(presets)
    }
}
