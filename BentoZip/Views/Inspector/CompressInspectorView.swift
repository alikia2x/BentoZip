import AppKit
import BentoZipCore
import SwiftUI

struct CompressInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showPasswordSheet = false
    @State private var savedFeedbackVisible: Bool = false
    @State private var feedbackTask: Task<Void, Never>?
    @State private var presets: [ArchivePreset] = []
    @State private var showSavePresetSheet: Bool = false
    @State private var newPresetName: String = ""

    var body: some View {
        @Bindable var appState = appState

        InspectorScrollContainer {
            InspectorCard {
                InspectorRow("Preset") {
                    Menu {
                        ForEach(presets) { preset in
                            Button {
                                appState.applyPreset(preset)
                            } label: {
                                if selectedPreset?.id == preset.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                        Divider()
                        Button("Save as Preset…") {
                            newPresetName = ""
                            showSavePresetSheet = true
                        }
                    } label: {
                        InspectorMenuLabel(title: selectedPreset?.name ?? String(localized: "Custom"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

            }

            InspectorCard {
                InspectorRow("Format") {
                    Menu {
                        ForEach(ArchiveFormat.allCases) { format in
                            Button {
                                appState.updateCompressionFormat(to: format)
                            } label: {
                                if appState.compressionSettings.format == format {
                                    Label(format.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(format.rawValue)
                                }
                            }
                        }
                    } label: {
                        InspectorMenuLabel(title: appState.compressionSettings.format.rawValue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

                InspectorRowDivider()

                InspectorRow("Level") {
                    Menu {
                        ForEach(CompressionLevel.allCases) { level in
                            Button {
                                appState.compressionSettings.compressionLevel = level
                            } label: {
                                if appState.compressionSettings.compressionLevel == level {
                                    Label(level.localizedName, systemImage: "checkmark")
                                } else {
                                    Text(level.localizedName)
                                }
                            }
                        }
                    } label: {
                        InspectorMenuLabel(title: appState.compressionSettings.compressionLevel.localizedName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

                InspectorRowDivider()

                InspectorRow("Name") {
                    TextField(
                        "",
                        text: $appState.compressionSettings.archiveName,
                        prompt: Text(appState.suggestedArchiveName)
                    )
                    .labelsHidden()
                    .accessibilityLabel(Text("Name"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .padding(.vertical, 4)
                }

                if supportsPasswordEncryption {
                    InspectorRowDivider()
                    InspectorRow("Password") {
                        Button((appState.compressionSettings.password ?? "").isEmpty ? "Set Password…" : "Change Password…") {
                            showPasswordSheet = true
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("compression.password.button")
                    }

                    if appState.compressionSettings.format == .zip && !(appState.compressionSettings.password ?? "").isEmpty {
                        InspectorRowDivider()

                        InspectorRow("Encryption") {
                            Menu {
                                ForEach(ZipEncryptionMethod.allCases) { method in
                                    Button {
                                        appState.compressionSettings.zipEncryptionMethod = method
                                    } label: {
                                        if appState.compressionSettings.zipEncryptionMethod == method {
                                            Label(method.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(method.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                InspectorMenuLabel(title: appState.compressionSettings.zipEncryptionMethod.rawValue)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    } else if appState.compressionSettings.format == .sevenZip && !(appState.compressionSettings.password ?? "").isEmpty {
                        InspectorRowDivider()

                        InspectorToggleRow("Encrypt Filenames", isOn: $appState.compressionSettings.encryptHeaders)
                    }
                }

                if appState.compressionSettings.format.supportsSplitVolumes {
                    InspectorRowDivider()

                    InspectorRow("Split Volumes") {
                        Menu {
                            ForEach(Self.volumeSizeOptions, id: \.bytes) { option in
                                Button {
                                    appState.compressionSettings.volumeSizeBytes = option.bytes
                                } label: {
                                    if appState.compressionSettings.volumeSizeBytes == option.bytes {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                            }
                        } label: {
                            InspectorMenuLabel(title: currentVolumeSizeTitle)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            InspectorCard {
                InspectorToggleRow("Preserve Folders", isOn: $appState.compressionSettings.preserveDirectoryStructure)
                InspectorRowDivider()
                InspectorToggleRow("Follow Symlinks", isOn: $appState.compressionSettings.followSymlinks)
                if appState.rootNodes.count > 1 {
                    InspectorRowDivider()
                    InspectorToggleRow("Compress each item separately", isOn: $appState.compressionSettings.compressEachSeparately)
                }
            }

            InspectorCard("Exclude") {
                ExclusionPatternsEditor(patterns: $appState.compressionSettings.exclusionPatterns)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Button("Save as Default") {
                        appState.savePreferences()
                        feedbackTask?.cancel()
                        withAnimation(.easeOut(duration: 0.14)) {
                            savedFeedbackVisible = true
                        }
                        feedbackTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeOut(duration: 0.14)) {
                                savedFeedbackVisible = false
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())

                    if savedFeedbackVisible {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }

                    Spacer()

                    Button {
                        Task {
                            await appState.coordinator.compress(
                                appState: appState,
                                progressState: progressState
                            )
                        }
                    } label: {
                        Text("Compress")
                            .frame(minWidth: 68)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(appState.rootNodes.isEmpty || appState.isLoading || progressState.isOperationInProgress)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .onAppear {
            reloadPresets()
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesManager.preferencesDidChangeNotification)) { _ in
            reloadPresets()
        }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
        .sheet(isPresented: $showPasswordSheet) {
            CompressionPasswordSheet(password: appState.compressionSettings.password) { password in
                appState.compressionSettings.password = password
            }
        }
        .sheet(isPresented: $showSavePresetSheet) {
            SavePresetSheet(name: $newPresetName) { presetName in
                let preset = ArchivePreset(name: presetName, settings: appState.compressionSettings)
                appState.preferencesManager?.addPreset(preset)
                reloadPresets()
            }
        }
    }

    private static let volumeSizeOptions: [(bytes: Int64, title: String)] = [
        (0, String(localized: "Single File")),
        (10 * 1024 * 1024, String(localized: "10 MB")),
        (100 * 1024 * 1024, String(localized: "100 MB")),
        (500 * 1024 * 1024, String(localized: "500 MB")),
        (1024 * 1024 * 1024, String(localized: "1 GB")),
        (2 * 1024 * 1024 * 1024, String(localized: "2 GB")),
        (4 * 1024 * 1024 * 1024, String(localized: "4 GB")),
    ]

    private var currentVolumeSizeTitle: String {
        Self.volumeSizeOptions.first { $0.bytes == appState.compressionSettings.volumeSizeBytes }?.title
            ?? String(localized: "Single File")
    }

    private var selectedPreset: ArchivePreset? {
        let current = appState.compressionSettings
        return presets.first { preset in
            ArchivePreset(id: preset.id, name: preset.name, settings: current) == preset
        }
    }

    private func reloadPresets() {
        presets = appState.preferencesManager?.loadPresets() ?? ArchivePreset.builtInDefaults
    }

    private var supportsPasswordEncryption: Bool {
        appState.compressionSettings.format == .zip || appState.compressionSettings.format == .sevenZip
    }


}

private struct SavePresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    let onSave: (String) -> Void
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Compression Preset")
                .font(.system(size: 14, weight: .semibold))

            TextField("", text: $name, prompt: Text("Preset Name"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isNameFocused)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .onSubmit {
                    if !trimmedName.isEmpty {
                        onSave(trimmedName)
                        dismiss()
                    }
                }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(trimmedName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isNameFocused = true
        }
    }
}


private struct CompressionPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password: String
    @State private var isVisible = false
    @FocusState private var isFocused: Bool
    let onSave: (String?) -> Void

    init(password: String?, onSave: @escaping (String?) -> Void) {
        _password = State(initialValue: password ?? "")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archive Password")
                .font(.headline)

            HStack(spacing: 10) {
                Group {
                    if isVisible {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { save() }

                Button {
                    isVisible.toggle()
                    isFocused = true
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isVisible ? "Hide Password" : "Show Password"))
            }
            .padding(.vertical, 2)

            Text("Leave blank to remove password.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { isFocused = true }
    }

    private func save() {
        onSave(password.isEmpty ? nil : password)
        dismiss()
    }
}
