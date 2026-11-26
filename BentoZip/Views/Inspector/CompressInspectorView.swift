import AppKit
import BentoZipCore
import SwiftUI

struct CompressInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showPassword: Bool = false
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
                    } label: {
                        InspectorMenuLabel(title: selectedPreset?.name ?? String(localized: "Custom"))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

                InspectorRowDivider()

                HStack {
                    Spacer()
                    Button("Save as Preset…") {
                        newPresetName = ""
                        showSavePresetSheet = true
                    }
                    .buttonStyle(InspectorPillButtonStyle(compact: true))
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
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .modifier(InspectorInputWellModifier())
                }

                if supportsPasswordEncryption {
                    InspectorRowDivider()

                    InspectorRow("Password") {
                        HStack(spacing: 4) {
                            Group {
                                if showPassword {
                                    TextField("", text: passwordBinding, prompt: Text("Optional"))
                                } else {
                                    SecureField("", text: passwordBinding, prompt: Text("Optional"))
                                }
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)

                            if !(appState.compressionSettings.password ?? "").isEmpty {
                                Button {
                                    appState.compressionSettings.password = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Clear Password"))
                                .help("Clear Password")
                            }

                            Button {
                                let generated = PasswordGenerator.generate()
                                appState.compressionSettings.password = generated
                                showPassword = true
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generated, forType: .string)
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Generate Strong Password"))
                            .help("Generate Strong Password")

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(showPassword ? "Hide Password" : "Show Password"))
                            .help(showPassword ? "Hide Password" : "Show Password")
                        }
                        .modifier(InspectorInputWellModifier())
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

    private var passwordBinding: Binding<String> {
        Binding(
            get: { appState.compressionSettings.password ?? "" },
            set: { appState.compressionSettings.password = $0.isEmpty ? nil : $0 }
        )
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
