import AppKit
import BentoZipCore
import SwiftUI

struct CompressInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState

    @State private var showPassword: Bool = false
    @State private var savedFeedbackVisible: Bool = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                Picker("Format", selection: formatBinding) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("Level", selection: $appState.compressionSettings.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.localizedName).tag(level)
                    }
                }

                LabeledContent("Name") {
                    TextField(
                        "",
                        text: $appState.compressionSettings.archiveName,
                        prompt: Text(appState.suggestedArchiveName)
                    )
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                }

                if supportsPasswordEncryption {
                    LabeledContent("Password") {
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
                    }

                    if appState.compressionSettings.format == .zip && !(appState.compressionSettings.password ?? "").isEmpty {
                        Picker("Encryption", selection: $appState.compressionSettings.zipEncryptionMethod) {
                            ForEach(ZipEncryptionMethod.allCases) { method in
                                Text(method.rawValue).tag(method)
                            }
                        }
                    }
                }

                if appState.compressionSettings.format.supportsSplitVolumes {
                    Picker("Split Volumes", selection: $appState.compressionSettings.volumeSizeBytes) {
                        Text("Single File").tag(Int64(0))
                        Text("10 MB").tag(Int64(10 * 1024 * 1024))
                        Text("100 MB").tag(Int64(100 * 1024 * 1024))
                        Text("500 MB").tag(Int64(500 * 1024 * 1024))
                        Text("1 GB").tag(Int64(1024 * 1024 * 1024))
                        Text("2 GB").tag(Int64(2 * 1024 * 1024 * 1024))
                        Text("4 GB").tag(Int64(4 * 1024 * 1024 * 1024))
                    }
                }
            }

            Section {
                Toggle("Preserve Folders", isOn: $appState.compressionSettings.preserveDirectoryStructure)
            }

            Section("Exclude") {
                ExclusionPatternsEditor(patterns: $appState.compressionSettings.exclusionPatterns)
            }
        }
        .formStyle(.grouped)
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
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    private var supportsPasswordEncryption: Bool {
        appState.compressionSettings.format == .zip || appState.compressionSettings.format == .sevenZip
    }

    private var formatBinding: Binding<ArchiveFormat> {
        Binding(
            get: { appState.compressionSettings.format },
            set: { appState.updateCompressionFormat(to: $0) }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { appState.compressionSettings.password ?? "" },
            set: { appState.compressionSettings.password = $0.isEmpty ? nil : $0 }
        )
    }
}
