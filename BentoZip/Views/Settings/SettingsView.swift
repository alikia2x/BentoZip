import SwiftUI
import SwiftData
import BentoZipCore

struct SettingsView: View {
    let preferencesManager: PreferencesManager

    @State private var defaultFormat: ArchiveFormat = .zip
    @State private var defaultLevel: CompressionLevel = .normal
    @State private var revealInFinderAfterExtract: Bool = true
    @State private var unwrapSingleTopDirectory: Bool = true
    @State private var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    @State private var maxCacheSizeMB: Int = 2048
    @State private var cacheUsageBytes: Int64 = 0
    @State private var hasLoaded: Bool = false

    private static let cacheLimitOptions: [Int] = [0, 512, 1024, 2048, 4096]

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Format", selection: $defaultFormat) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("Compression", selection: $defaultLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.localizedName).tag(level)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Reveal in Finder when finished", isOn: $revealInFinderAfterExtract)
                Toggle("Unwrap single top-level folder on extract", isOn: $unwrapSingleTopDirectory)
            }

            Section("Cache") {
                Picker("Disk Cache Limit", selection: $maxCacheSizeMB) {
                    ForEach(Self.cacheLimitOptions, id: \.self) { mb in
                        Text(cacheLimitLabel(for: mb)).tag(mb)
                    }
                }

                LabeledContent("Current Usage") {
                    HStack(spacing: 10) {
                        Text(Self.byteFormatter.string(fromByteCount: cacheUsageBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Button("Clear Cache") {
                            ArchiveCacheManager.shared.clearCache()
                            refreshCacheStats()
                        }
                        .controlSize(.small)
                        .disabled(cacheUsageBytes == 0)
                    }
                }
            }

            Section("Default Exclusions") {
                ExclusionPatternsEditor(
                    patterns: $exclusionPatterns,
                    showResetButton: true
                ) {
                    persistChanges()
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadFromPreferences()
            refreshCacheStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.preferencesDidChangeNotification)) { _ in
            loadFromPreferences()
        }
        .onChange(of: defaultFormat) { _, _ in persistChanges() }
        .onChange(of: defaultLevel) { _, _ in persistChanges() }
        .onChange(of: revealInFinderAfterExtract) { _, _ in persistChanges() }
        .onChange(of: unwrapSingleTopDirectory) { _, _ in persistChanges() }
        .onChange(of: maxCacheSizeMB) { _, _ in
            persistChanges()
            refreshCacheStats()
        }
    }

    private func cacheLimitLabel(for megabytes: Int) -> String {
        switch megabytes {
        case 0: return String(localized: "Off")
        case 512: return "512 MB"
        case 1024: return "1 GB"
        case 2048: return "2 GB"
        case 4096: return "4 GB"
        default: return "\(megabytes) MB"
        }
    }

    private func refreshCacheStats() {
        Task.detached(priority: .utility) {
            let stats = ArchiveCacheManager.shared.stats()
            await MainActor.run {
                cacheUsageBytes = stats.totalBytes
            }
        }
    }

    private func loadFromPreferences() {
        let prefs = preferencesManager.loadPreferences()
        defaultFormat = ArchiveFormat.fromPersistedValue(prefs.defaultFormat) ?? .zip
        defaultLevel = CompressionLevel(rawValue: prefs.defaultCompressionLevel) ?? .normal
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        exclusionPatterns = prefs.exclusionPatterns
        maxCacheSizeMB = Self.cacheLimitOptions.contains(prefs.maxCacheSizeMB) ? prefs.maxCacheSizeMB : 2048
        hasLoaded = true
    }

    private func persistChanges() {
        guard hasLoaded else { return }
        let current = preferencesManager.loadPreferences()
        guard current.defaultFormat != defaultFormat.rawValue
            || current.defaultCompressionLevel != defaultLevel.rawValue
            || current.revealInFinderAfterExtract != revealInFinderAfterExtract
            || current.unwrapSingleTopDirectory != unwrapSingleTopDirectory
            || current.exclusionPatterns != exclusionPatterns
            || current.maxCacheSizeMB != maxCacheSizeMB else {
            return
        }

        preferencesManager.updatePreferences { prefs in
            prefs.defaultFormat = defaultFormat.rawValue
            prefs.defaultCompressionLevel = defaultLevel.rawValue
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
            prefs.exclusionPatterns = exclusionPatterns
            prefs.maxCacheSizeMB = maxCacheSizeMB
        }
    }
}
