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

    private let formatColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 13) {
                    formatSection
                    levelSection(appState: appState)
                    outputNameSection(appState: appState)

                    if supportsPasswordEncryption {
                        passwordSection
                    }

                    Divider()

                    exclusionsSection(appState: appState)
                }
                .padding(14)
            }

            Divider()
            footerActions
        }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Format")

            LazyVGrid(columns: formatColumns, spacing: 6) {
                ForEach(ArchiveFormat.allCases) { format in
                    let selected = appState.compressionSettings.format == format
                    Button {
                        appState.updateCompressionFormat(to: format)
                    } label: {
                        Text(format.rawValue)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 27)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.055))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.clear : Color.primary.opacity(0.07),
                                        lineWidth: 0.75
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func levelSection(appState: AppState) -> some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 7) {
            sectionHeader("Compression")

            Picker("", selection: $appState.compressionSettings.compressionLevel) {
                ForEach(CompressionLevel.allCases) { level in
                    Text(level.shortLocalizedName).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
        }
    }

    private func outputNameSection(appState: AppState) -> some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 7) {
            sectionHeader("Output Name")

            TextField(
                "",
                text: $appState.compressionSettings.archiveName,
                prompt: Text(appState.suggestedArchiveName)
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader("Password")

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
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private func exclusionsSection(appState: AppState) -> some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 10) {
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

            VStack(alignment: .leading, spacing: 7) {
                sectionHeader("Exclude")
                ExclusionPatternsEditor(patterns: $appState.compressionSettings.exclusionPatterns)
            }
        }
    }

    private var footerActions: some View {
        VStack(spacing: 10) {
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
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(appState.fileEntries.isEmpty || appState.isLoading)

            HStack {
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
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())

                Spacer()

                if savedFeedbackVisible {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
        .padding(14)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private var supportsPasswordEncryption: Bool {
        appState.compressionSettings.format == .zip || appState.compressionSettings.format == .sevenZip
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { appState.compressionSettings.password ?? "" },
            set: { newValue in
                appState.compressionSettings.password = newValue.isEmpty ? nil : newValue
            }
        )
    }
}
