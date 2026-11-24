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
    @State private var hasLoaded: Bool = false

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
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.preferencesDidChangeNotification)) { _ in
            loadFromPreferences()
        }
        .onChange(of: defaultFormat) { _, _ in persistChanges() }
        .onChange(of: defaultLevel) { _, _ in persistChanges() }
        .onChange(of: revealInFinderAfterExtract) { _, _ in persistChanges() }
        .onChange(of: unwrapSingleTopDirectory) { _, _ in persistChanges() }
    }

    private func loadFromPreferences() {
        let prefs = preferencesManager.loadPreferences()
        defaultFormat = ArchiveFormat.fromPersistedValue(prefs.defaultFormat) ?? .zip
        defaultLevel = CompressionLevel(rawValue: prefs.defaultCompressionLevel) ?? .normal
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        exclusionPatterns = prefs.exclusionPatterns
        hasLoaded = true
    }

    private func persistChanges() {
        guard hasLoaded else { return }
        let current = preferencesManager.loadPreferences()
        guard current.defaultFormat != defaultFormat.rawValue
            || current.defaultCompressionLevel != defaultLevel.rawValue
            || current.revealInFinderAfterExtract != revealInFinderAfterExtract
            || current.unwrapSingleTopDirectory != unwrapSingleTopDirectory
            || current.exclusionPatterns != exclusionPatterns else {
            return
        }

        preferencesManager.updatePreferences { prefs in
            prefs.defaultFormat = defaultFormat.rawValue
            prefs.defaultCompressionLevel = defaultLevel.rawValue
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
            prefs.exclusionPatterns = exclusionPatterns
        }
    }
}
