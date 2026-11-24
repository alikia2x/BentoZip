import AppKit
import BentoZipCore
import SwiftUI

struct CompressInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @State private var showPassword: Bool = false
    @State private var savedFeedbackVisible: Bool = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 10) {
                        inspectorRow("Format") {
                            Picker("", selection: formatBinding) {
                                ForEach(ArchiveFormat.allCases) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        inspectorRow("Level") {
                            Picker("", selection: $appState.compressionSettings.compressionLevel) {
                                ForEach(CompressionLevel.allCases) { level in
                                    Text(level.localizedName).tag(level)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        inspectorRow("Name") {
                            TextField(
                                "",
                                text: $appState.compressionSettings.archiveName,
                                prompt: Text(appState.suggestedArchiveName)
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                        }

                        if supportsPasswordEncryption {
                            inspectorRow("Password") {
                                passwordField
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Preserve Folders")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.primary)

                            Spacer()

                            Toggle("", isOn: $appState.compressionSettings.preserveDirectoryStructure)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Exclude")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            ExclusionPatternsEditor(patterns: $appState.compressionSettings.exclusionPatterns)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }

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
                            progressState: progressState,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Text("Compress")
                        .frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(appState.fileEntries.isEmpty || appState.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    private func inspectorRow<Control: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 60, alignment: .trailing)

            control()
        }
    }

    private var passwordField: some View {
        HStack(spacing: 4) {
            Group {
                if showPassword {
                    TextField("", text: passwordBinding, prompt: Text("Optional"))
                } else {
                    SecureField("", text: passwordBinding, prompt: Text("Optional"))
                }
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))

            if !(appState.compressionSettings.password ?? "").isEmpty {
                Button {
                    appState.compressionSettings.password = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
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
