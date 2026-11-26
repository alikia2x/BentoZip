import AppKit
import BentoZipCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let preferencesManager: PreferencesManager

    // General
    @State private var defaultFormat: ArchiveFormat = .zip
    @State private var defaultLevel: CompressionLevel = .normal
    @State private var showHiddenFiles: Bool = false
    @State private var exclusionPatterns: [String] = [".DS_Store", "__MACOSX"]
    @State private var maxCacheSizeMB: Int = 2048
    @State private var cacheUsageBytes: Int64 = 0
    @State private var isCLIInstalled: Bool = false
    @State private var isUpdatingCLI: Bool = false
    @State private var cliErrorMessage: String?
    @State private var cliSuccessMessage: String?

    // Extraction
    @State private var archiveOpenAction: ArchiveOpenAction = .browse
    @State private var extractDestinationMode: ExtractDestinationMode = .sameFolder
    @State private var customExtractDirectory: String = ""
    @State private var extractConflictPolicy: ExtractConflictPolicy = .ask
    @State private var revealInFinderAfterExtract: Bool = true
    @State private var unwrapSingleTopDirectory: Bool = true
    @State private var moveArchiveToTrashAfterExtract: Bool = false
    @State private var closeWindowAfterExtract: Bool = false
    @State private var stripQuarantineOnExtract: Bool = false
    @State private var defaultViewMode: BrowserViewMode = .list

    // Presets
    @State private var presets: [ArchivePreset] = []
    @State private var newPresetName: String = ""
    @State private var newPresetFormat: ArchiveFormat = .zip
    @State private var newPresetLevel: CompressionLevel = .normal

    // Passwords Vault
    @State private var autoTryVaultPasswords: Bool = true
    @State private var isVaultUnlocked: Bool = false
    @State private var isAuthenticatingVault: Bool = false
    @State private var vaultAuthFailed: Bool = false
    @State private var vaultEntries: [PasswordVaultEntry] = []
    @State private var revealedVaultEntryIDs: Set<UUID> = []
    @State private var newVaultLabel: String = ""
    @State private var newVaultPassword: String = ""

    // Formats
    @State private var defaultFamilyStatus: [String: Bool] = [:]
    @State private var isUpdatingDefaults: Bool = false
    @State private var formatErrorMessage: String?

    @State private var hasLoaded: Bool = false

    private static let cacheLimitOptions: [Int] = [0, 512, 1024, 2048, 4096]

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            extractionTab
                .tabItem {
                    Label("Extraction", systemImage: "arrow.down.doc")
                }

            presetsTab
                .tabItem {
                    Label("Presets", systemImage: "slider.horizontal.3")
                }

            passwordsTab
                .tabItem {
                    Label("Passwords", systemImage: "key.fill")
                }

            formatsTab
                .tabItem {
                    Label("Formats", systemImage: "doc.zipper")
                }
        }
        .frame(width: 540, height: 520)
        .onAppear {
            loadFromPreferences()
            refreshCacheStats()
            refreshFormatDefaults()
            refreshCLIStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.preferencesDidChangeNotification)) { _ in
            loadFromPreferences()
        }
        .onChange(of: defaultFormat) { _, _ in persistChanges() }
        .onChange(of: defaultLevel) { _, _ in persistChanges() }
        .onChange(of: showHiddenFiles) { _, _ in persistChanges() }
        .onChange(of: defaultViewMode) { _, _ in persistChanges() }
        .onChange(of: maxCacheSizeMB) { _, _ in
            persistChanges()
            refreshCacheStats()
        }
        .onChange(of: archiveOpenAction) { _, _ in persistChanges() }
        .onChange(of: extractDestinationMode) { _, _ in persistChanges() }
        .onChange(of: customExtractDirectory) { _, _ in persistChanges() }
        .onChange(of: extractConflictPolicy) { _, _ in persistChanges() }
        .onChange(of: revealInFinderAfterExtract) { _, _ in persistChanges() }
        .onChange(of: unwrapSingleTopDirectory) { _, _ in persistChanges() }
        .onChange(of: moveArchiveToTrashAfterExtract) { _, _ in persistChanges() }
        .onChange(of: closeWindowAfterExtract) { _, _ in persistChanges() }
        .onChange(of: stripQuarantineOnExtract) { _, _ in persistChanges() }
        .onChange(of: autoTryVaultPasswords) { _, _ in persistChanges() }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Defaults") {
                Picker("Default Format", selection: $defaultFormat) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("Compression Level", selection: $defaultLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.localizedName).tag(level)
                    }
                }

                Picker("Default View", selection: $defaultViewMode) {
                    Text("List").tag(BrowserViewMode.list)
                    Text("Icons").tag(BrowserViewMode.grid)
                }

                Toggle("Show hidden files", isOn: $showHiddenFiles)
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

            Section("Command-Line Tool") {
                LabeledContent("Status") {
                    if isCLIInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Text("Not Installed")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Path") {
                    Text(CLIToolInstaller.defaultInstallPath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    if let cliErrorMessage {
                        Text(cliErrorMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red)
                    } else if let cliSuccessMessage {
                        Text(cliSuccessMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isUpdatingCLI {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if isCLIInstalled {
                        Button("Uninstall") {
                            Task {
                                await uninstallCLITool()
                            }
                        }
                        .controlSize(.small)
                        .disabled(isUpdatingCLI)
                    } else {
                        Button("Install CLI Tool…") {
                            Task {
                                await installCLITool()
                            }
                        }
                        .controlSize(.small)
                        .disabled(isUpdatingCLI)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Extraction Tab

    private var extractionTab: some View {
        Form {
            Section {
                Picker("Double-click Archive", selection: $archiveOpenAction) {
                    Text("Browse Contents").tag(ArchiveOpenAction.browse)
                    Text("Extract Immediately").tag(ArchiveOpenAction.extract)
                }
            } header: {
                Text("Opening Archives")
            } footer: {
                Text("Hold Option (⌥) while opening an archive to temporarily use the opposite action.")
            }

            Section("Destination & Conflicts") {
                Picker("Extract Destination", selection: $extractDestinationMode) {
                    Text("Same Folder as Archive").tag(ExtractDestinationMode.sameFolder)
                    Text("Ask Every Time").tag(ExtractDestinationMode.askEveryTime)
                    Text("Custom Folder").tag(ExtractDestinationMode.customFolder)
                }

                if extractDestinationMode == .customFolder {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(customFolderDisplayName)
                                .font(.system(size: 12))
                                .foregroundStyle(customExtractDirectory.isEmpty ? .tertiary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button("Choose…") {
                                chooseCustomExtractDirectory()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Picker("File Conflicts", selection: $extractConflictPolicy) {
                    Text("Ask Each Time").tag(ExtractConflictPolicy.ask)
                    Text("Overwrite").tag(ExtractConflictPolicy.overwrite)
                    Text("Skip").tag(ExtractConflictPolicy.skip)
                    Text("Keep Both").tag(ExtractConflictPolicy.rename)
                }
            }

            Section("After Extraction") {
                Toggle("Reveal in Finder when finished", isOn: $revealInFinderAfterExtract)
                Toggle("Unwrap single top-level folder", isOn: $unwrapSingleTopDirectory)
                Toggle("Move archive to Trash after extracting", isOn: $moveArchiveToTrashAfterExtract)
                Toggle("Close window after extracting", isOn: $closeWindowAfterExtract)
                Toggle("Remove quarantine flag from extracted files", isOn: $stripQuarantineOnExtract)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Presets Tab

    private var presetsTab: some View {
        Form {
            Section("Saved Presets") {
                if presets.isEmpty {
                    Text("No saved presets.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presets) { preset in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .medium))

                                Text("\(preset.format.rawValue) - \(preset.compressionLevel.localizedName)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                preferencesManager.deletePreset(id: preset.id)
                                presets = preferencesManager.loadPresets()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete Preset")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("New Preset") {
                LabeledContent("Name") {
                    TextField("", text: $newPresetName, prompt: Text("e.g. Fast ZIP"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Format", selection: $newPresetFormat) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("Compression Level", selection: $newPresetLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.localizedName).tag(level)
                    }
                }

                HStack {
                    Spacer()
                    Button("Add Preset") {
                        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let preset = ArchivePreset(
                            name: trimmed,
                            format: newPresetFormat,
                            compressionLevel: newPresetLevel,
                            exclusionPatterns: exclusionPatterns
                        )
                        preferencesManager.addPreset(preset)
                        presets = preferencesManager.loadPresets()
                        newPresetName = ""
                    }
                    .controlSize(.small)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        preferencesManager.savePresets(ArchivePreset.builtInDefaults)
                        presets = preferencesManager.loadPresets()
                    }
                    .controlSize(.regular)
                    .disabled(presets == ArchivePreset.builtInDefaults)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    // MARK: - Passwords Tab

    private var passwordsTab: some View {
        Form {
            Section {
                Toggle("Auto-try saved passwords", isOn: $autoTryVaultPasswords)
            } header: {
                Text("Auto-Unlock")
            } footer: {
                Text("Automatically try passwords saved in your Keychain Vault when opening encrypted archives.")
            }

            Section("Keychain Password Vault") {
                if !isVaultUnlocked {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Vault Locked")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Authenticate with Touch ID or your macOS password to view and manage saved passwords.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if vaultAuthFailed {
                            Text("Authentication was cancelled or failed.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Spacer()
                            if isAuthenticatingVault {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("Unlock Vault") {
                                unlockVault()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isAuthenticatingVault)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    if vaultEntries.isEmpty {
                        Text("No saved passwords.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vaultEntries) { entry in
                            let isRevealed = revealedVaultEntryIDs.contains(entry.id)
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)

                                    Text(isRevealed ? entry.password : "••••••••••••")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button {
                                    if isRevealed {
                                        revealedVaultEntryIDs.remove(entry.id)
                                    } else {
                                        revealedVaultEntryIDs.insert(entry.id)
                                    }
                                } label: {
                                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(isRevealed ? "Hide Password" : "Show Password")

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.password, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy")

                                Button(role: .destructive) {
                                    PasswordVaultService.shared.deleteEntry(id: entry.id)
                                    vaultEntries = PasswordVaultService.shared.loadEntries()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Delete")
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            TextField("", text: $newVaultLabel, prompt: Text("Label (e.g. Work Archive)"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)

                            TextField("", text: $newVaultPassword, prompt: Text("Password"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)

                            Button {
                                let generated = PasswordGenerator.generate()
                                newVaultPassword = generated
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generated, forType: .string)
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Generate Strong Password")

                            Button("Add") {
                                guard !newVaultPassword.isEmpty else { return }
                                PasswordVaultService.shared.addEntry(
                                    label: newVaultLabel,
                                    password: newVaultPassword
                                )
                                vaultEntries = PasswordVaultService.shared.loadEntries()
                                newVaultLabel = ""
                                newVaultPassword = ""
                            }
                            .controlSize(.small)
                            .disabled(newVaultPassword.isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isVaultUnlocked {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Lock Vault") {
                            isVaultUnlocked = false
                            vaultEntries = []
                            revealedVaultEntryIDs.removeAll()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
                }
            }
        }
    }

    private func unlockVault() {
        isAuthenticatingVault = true
        vaultAuthFailed = false
        Task {
            let authenticated = await PasswordVaultService.shared.authenticateWithBiometrics(
                reason: String(localized: "Unlock saved archive passwords")
            )
            isAuthenticatingVault = false
            if authenticated {
                isVaultUnlocked = true
                vaultEntries = PasswordVaultService.shared.loadEntries()
            } else {
                vaultAuthFailed = true
            }
        }
    }

    // MARK: - Formats Tab

    private var formatsTab: some View {
        Form {
            Section {
                ForEach(ArchiveFormatFamily.allFamilies) { family in
                    let isDefault = defaultFamilyStatus[family.id] == true
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(family.title)
                                .font(.system(size: 13, weight: .medium))

                            Text(family.extensionsSummary)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isDefault {
                            Label("Default", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.green)
                        } else {
                            Button("Set as Default") {
                                Task {
                                    await setDefaultApplication(for: [family])
                                }
                            }
                            .controlSize(.small)
                            .disabled(isUpdatingDefaults)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Default Handler Registration")
            } footer: {
                if let formatErrorMessage {
                    Text(formatErrorMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("Set BentoZip as the default application when opening archive files in Finder.")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button("Set All as Default") {
                        Task {
                            await setDefaultApplication(for: ArchiveFormatFamily.allFamilies)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpdatingDefaults || allFamiliesDefault)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }

    // MARK: - Helpers

    private var customFolderDisplayName: String {
        if customExtractDirectory.isEmpty {
            return String(localized: "No folder selected")
        }
        return URL(fileURLWithPath: customExtractDirectory).lastPathComponent
    }

    private var allFamiliesDefault: Bool {
        ArchiveFormatFamily.allFamilies.allSatisfy { defaultFamilyStatus[$0.id] == true }
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

    private func chooseCustomExtractDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if !customExtractDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customExtractDirectory, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customExtractDirectory = url.path
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

    private func refreshCLIStatus() {
        isCLIInstalled = CLIToolInstaller().isInstalled
    }

    private func installCLITool() async {
        isUpdatingCLI = true
        cliErrorMessage = nil
        cliSuccessMessage = nil
        defer {
            isUpdatingCLI = false
            refreshCLIStatus()
        }
        do {
            try await CLIToolInstaller().install()
            cliSuccessMessage = String(localized: "Installed to \(CLIToolInstaller.defaultInstallPath).")
        } catch let error as CLIToolInstallerError where error == .cancelled {
            return
        } catch {
            cliErrorMessage = error.localizedDescription
        }
    }

    private func uninstallCLITool() async {
        isUpdatingCLI = true
        cliErrorMessage = nil
        cliSuccessMessage = nil
        defer {
            isUpdatingCLI = false
            refreshCLIStatus()
        }
        do {
            try await CLIToolInstaller().uninstall()
            cliSuccessMessage = String(localized: "CLI tool removed.")
        } catch let error as CLIToolInstallerError where error == .cancelled {
            return
        } catch {
            cliErrorMessage = error.localizedDescription
        }
    }

    private func refreshFormatDefaults() {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let workspace = NSWorkspace.shared
        var updated: [String: Bool] = [:]
        for family in ArchiveFormatFamily.allFamilies {
            let types = family.resolvedUTTypes
            if types.isEmpty {
                updated[family.id] = false
            } else {
                updated[family.id] = types.allSatisfy { type in
                    workspace.urlForApplication(toOpen: type)?.standardizedFileURL == appURL
                }
            }
        }
        defaultFamilyStatus = updated
    }

    private func setDefaultApplication(for families: [ArchiveFormatFamily]) async {
        isUpdatingDefaults = true
        formatErrorMessage = nil
        defer {
            isUpdatingDefaults = false
            refreshFormatDefaults()
        }

        let appURL = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        var firstError: Error?

        for family in families {
            for type in family.resolvedUTTypes {
                do {
                    try await workspace.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        if let firstError {
            formatErrorMessage = firstError.localizedDescription
        }
    }

    private func loadFromPreferences() {
        let prefs = preferencesManager.loadPreferences()
        defaultFormat = ArchiveFormat.fromPersistedValue(prefs.defaultFormat) ?? .zip
        defaultLevel = CompressionLevel(rawValue: prefs.defaultCompressionLevel) ?? .normal
        showHiddenFiles = prefs.showHiddenFiles
        exclusionPatterns = prefs.exclusionPatterns
        maxCacheSizeMB = Self.cacheLimitOptions.contains(prefs.maxCacheSizeMB) ? prefs.maxCacheSizeMB : 2048

        archiveOpenAction = ArchiveOpenAction(rawValue: prefs.archiveOpenAction) ?? .browse
        extractDestinationMode = ExtractDestinationMode(rawValue: prefs.extractDestinationMode) ?? .sameFolder
        customExtractDirectory = prefs.customExtractDirectory ?? ""
        extractConflictPolicy = ExtractConflictPolicy(rawValue: prefs.extractConflictPolicy) ?? .ask
        revealInFinderAfterExtract = prefs.revealInFinderAfterExtract
        unwrapSingleTopDirectory = prefs.unwrapSingleTopDirectory
        moveArchiveToTrashAfterExtract = prefs.moveArchiveToTrashAfterExtract
        closeWindowAfterExtract = prefs.closeWindowAfterExtract
        stripQuarantineOnExtract = prefs.stripQuarantineOnExtract
        autoTryVaultPasswords = prefs.autoTryVaultPasswords
        defaultViewMode = BrowserViewMode(rawValue: prefs.defaultViewMode) ?? .list
        presets = preferencesManager.loadPresets()

        hasLoaded = true
    }

    private func persistChanges() {
        guard hasLoaded else { return }
        let normalizedCustomDir: String? = customExtractDirectory.isEmpty ? nil : customExtractDirectory
        let current = preferencesManager.loadPreferences()
        guard current.defaultFormat != defaultFormat.rawValue
            || current.defaultCompressionLevel != defaultLevel.rawValue
            || current.showHiddenFiles != showHiddenFiles
            || current.exclusionPatterns != exclusionPatterns
            || current.maxCacheSizeMB != maxCacheSizeMB
            || current.archiveOpenAction != archiveOpenAction.rawValue
            || current.extractDestinationMode != extractDestinationMode.rawValue
            || current.customExtractDirectory != normalizedCustomDir
            || current.extractConflictPolicy != extractConflictPolicy.rawValue
            || current.revealInFinderAfterExtract != revealInFinderAfterExtract
            || current.unwrapSingleTopDirectory != unwrapSingleTopDirectory
            || current.moveArchiveToTrashAfterExtract != moveArchiveToTrashAfterExtract
            || current.closeWindowAfterExtract != closeWindowAfterExtract
            || current.stripQuarantineOnExtract != stripQuarantineOnExtract
            || current.autoTryVaultPasswords != autoTryVaultPasswords
            || current.defaultViewMode != defaultViewMode.rawValue else {
            return
        }

        preferencesManager.updatePreferences { prefs in
            prefs.defaultFormat = defaultFormat.rawValue
            prefs.defaultCompressionLevel = defaultLevel.rawValue
            prefs.showHiddenFiles = showHiddenFiles
            prefs.exclusionPatterns = exclusionPatterns
            prefs.maxCacheSizeMB = maxCacheSizeMB
            prefs.archiveOpenAction = archiveOpenAction.rawValue
            prefs.extractDestinationMode = extractDestinationMode.rawValue
            prefs.customExtractDirectory = normalizedCustomDir
            prefs.extractConflictPolicy = extractConflictPolicy.rawValue
            prefs.revealInFinderAfterExtract = revealInFinderAfterExtract
            prefs.unwrapSingleTopDirectory = unwrapSingleTopDirectory
            prefs.moveArchiveToTrashAfterExtract = moveArchiveToTrashAfterExtract
            prefs.closeWindowAfterExtract = closeWindowAfterExtract
            prefs.stripQuarantineOnExtract = stripQuarantineOnExtract
            prefs.autoTryVaultPasswords = autoTryVaultPasswords
            prefs.defaultViewMode = defaultViewMode.rawValue
        }
    }
}

private struct ArchiveFormatFamily: Identifiable {
    let id: String
    let title: String
    let extensionsSummary: String
    let typeIdentifiers: [String]
    let filenameExtensions: [String]

    var resolvedUTTypes: [UTType] {
        var seen = Set<String>()
        var result: [UTType] = []
        for identifier in typeIdentifiers {
            if let type = UTType(identifier), seen.insert(type.identifier).inserted {
                result.append(type)
            }
        }
        for ext in filenameExtensions {
            if let type = UTType(filenameExtension: ext), !type.isDynamic, seen.insert(type.identifier).inserted {
                result.append(type)
            }
        }
        return result
    }

    static let allFamilies: [ArchiveFormatFamily] = [
        ArchiveFormatFamily(
            id: "zip",
            title: "ZIP",
            extensionsSummary: ".zip, .zipx",
            typeIdentifiers: ["public.zip-archive", "com.pkware.zip-archive", "com.winzip.zipx-archive"],
            filenameExtensions: ["zip", "zipx"]
        ),
        ArchiveFormatFamily(
            id: "7z",
            title: "7z",
            extensionsSummary: ".7z",
            typeIdentifiers: ["org.7-zip.7-zip-archive"],
            filenameExtensions: ["7z"]
        ),
        ArchiveFormatFamily(
            id: "rar",
            title: "RAR",
            extensionsSummary: ".rar",
            typeIdentifiers: ["com.rarlab.rar-archive"],
            filenameExtensions: ["rar"]
        ),
        ArchiveFormatFamily(
            id: "tar",
            title: String(localized: "TAR & Compressed Tarballs"),
            extensionsSummary: ".tar, .tar.gz, .tgz, .tar.bz2, .tbz, .tar.xz, .txz, .gz, .bz2, .xz",
            typeIdentifiers: [
                "public.tar-archive",
                "org.gnu.gnu-zip-tar-archive",
                "org.gnu.gnu-zip-archive",
                "public.bzip2-archive",
                "public.tar-bzip2-archive",
                "org.tukaani.xz-archive",
                "org.tukaani.tar-xz-archive"
            ],
            filenameExtensions: ["tar", "tgz", "gz", "bz2", "tbz", "tbz2", "xz", "txz"]
        ),
        ArchiveFormatFamily(
            id: "zstd",
            title: "Zstandard",
            extensionsSummary: ".zst, .tar.zst, .tzst",
            typeIdentifiers: [
                "com.facebook.zstandard-archive",
                "com.facebook.zst-archive",
                "com.facebook.tar-zst-archive"
            ],
            filenameExtensions: ["zst", "tzst"]
        ),
        ArchiveFormatFamily(
            id: "aar",
            title: "Apple Archive",
            extensionsSummary: ".aar, .yaa",
            typeIdentifiers: ["com.apple.archive", "com.bentozip.apple-archive"],
            filenameExtensions: ["aar", "yaa"]
        )
    ]
}
