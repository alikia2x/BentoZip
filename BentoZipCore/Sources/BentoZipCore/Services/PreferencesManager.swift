import Foundation
import SwiftData

@MainActor
public final class PreferencesManager {
    private var modelContext: ModelContext?

    public init() {}

    public func configure(with context: ModelContext) {
        self.modelContext = context
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
    }

    public func applyDefaults(to settings: inout CompressionSettings, from prefs: AppPreferences) {
        if let format = ArchiveFormat(rawValue: prefs.defaultFormat) {
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
}
