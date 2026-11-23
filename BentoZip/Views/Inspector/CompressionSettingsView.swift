import BentoZipCore
import SwiftUI

struct CompressionSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.openWindow) private var openWindow

    @State private var newPattern: String = ""
    @State private var showPassword: Bool = false
    @State private var savedFeedbackVisible: Bool = false
    @State private var feedbackTask: Task<Void, Never>?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Group {
            switch appState.mode {
            case .compress:
                compressInspector
            case .browseArchive:
                archiveInspector
            case .empty:
                ContentUnavailableView(
                    "无活动项目",
                    systemImage: "sidebar.trailing",
                    description: Text("添加文件或打开压缩包后可在此配置参数或查看详情")
                )
            }
        }
    }

    // MARK: - Compress Mode Inspector

    private var compressInspector: some View {
        @Bindable var appState = appState

        return Form {
            Section("基本设置") {
                Picker("格式", selection: formatSelectionBinding) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("压缩级别", selection: $appState.compressionSettings.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }

                TextField(
                    "压缩包名称",
                    text: $appState.compressionSettings.archiveName,
                    prompt: Text(appState.suggestedArchiveName)
                )
            }

            Section {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            TextField("输入密码（可选）", text: passwordBinding)
                        } else {
                            SecureField("输入密码（可选）", text: passwordBinding)
                        }
                    }
                    .textFieldStyle(.plain)

                    if !(appState.compressionSettings.password ?? "").isEmpty {
                        Button {
                            appState.compressionSettings.password = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, minHeight: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("清除密码")
                    }

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "隐藏密码" : "显示密码")
                }

                if !supportsPasswordEncryption {
                    Label("当前格式不支持加密，仅 ZIP 与 7z 支持密码保护", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("安全加密")
            }

            Section("路径与过滤") {
                Toggle("保留目录结构", isOn: $appState.compressionSettings.preserveDirectoryStructure)

                if appState.compressionSettings.exclusionPatterns.isEmpty {
                    Text("未设置排除规则")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.compressionSettings.exclusionPatterns, id: \.self) { pattern in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(pattern)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button {
                                removePattern(pattern)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 22, minHeight: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("移除排除规则")
                        }
                    }
                }

                HStack(spacing: 6) {
                    TextField("新增排除规则（如 *.log）", text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addPattern()
                        }

                    Button("添加") {
                        addPattern()
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                HStack {
                    Button("保存为默认设置") {
                        appState.savePreferences()
                        feedbackTask?.cancel()
                        withAnimation(.snappy(duration: 0.2)) {
                            savedFeedbackVisible = true
                        }
                        feedbackTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            guard !Task.isCancelled else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                savedFeedbackVisible = false
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if savedFeedbackVisible {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    // MARK: - Browse Archive Inspector

    private var archiveInspector: some View {
        let totalCount = appState.totalEntryCount
        let uncompressedStr = Self.byteFormatter.string(fromByteCount: appState.totalSize)

        return Form {
            Section("归档详情") {
                LabeledContent("文件名") {
                    Text(appState.sourceArchiveURL?.lastPathComponent ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                LabeledContent("格式") {
                    Text(appState.archiveFormatName ?? "未知")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.14))
                        )
                }

                LabeledContent("写入权限") {
                    if appState.isReadOnlyArchive {
                        Label("只读", systemImage: "lock.doc")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("可编辑", systemImage: "pencil.circle")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }

                LabeledContent("加密状态") {
                    if appState.isArchiveEncrypted {
                        Label("已加密", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        Text("未加密")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("体积统计") {
                LabeledContent("总项目数") {
                    Text("\(totalCount) 项")
                        .monospacedDigit()
                }

                LabeledContent("原始大小") {
                    Text(uncompressedStr)
                        .monospacedDigit()
                }

                if let packed = appState.totalPackedSize, packed > 0 {
                    LabeledContent("压缩后大小") {
                        Text(Self.byteFormatter.string(fromByteCount: packed))
                            .monospacedDigit()
                    }

                    if appState.totalSize > 0 && packed <= appState.totalSize {
                        let savings = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
                        LabeledContent("空间节省") {
                            Text("\(savings)%")
                                .foregroundStyle(.green)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section("快速操作") {
                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: false,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Label("解压到当前目录", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await appState.coordinator.extract(
                            appState: appState,
                            progressState: progressState,
                            chooseDestination: true,
                            openWindow: openWindow
                        )
                    }
                } label: {
                    Label("解压到指定位置...", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                if !appState.selectedEntries.isEmpty {
                    Button {
                        Task {
                            await appState.coordinator.extract(
                                appState: appState,
                                progressState: progressState,
                                entries: appState.selectedEntries,
                                chooseDestination: true,
                                openWindow: openWindow
                            )
                        }
                    } label: {
                        Label("解压所选项目 (\(appState.selectedEntries.count))", systemImage: "checkmark.rectangle.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var supportsPasswordEncryption: Bool {
        let format = appState.compressionSettings.format
        return format == .zip || format == .sevenZip
    }

    private var formatSelectionBinding: Binding<ArchiveFormat> {
        Binding(
            get: { appState.compressionSettings.format },
            set: { newFormat in
                appState.updateCompressionFormat(to: newFormat)
            }
        )
    }

    private var passwordBinding: Binding<String> {
        Binding(
            get: { appState.compressionSettings.password ?? "" },
            set: { newValue in
                appState.compressionSettings.password = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !appState.compressionSettings.exclusionPatterns.contains(trimmed) {
            appState.compressionSettings.exclusionPatterns.append(trimmed)
        }
        newPattern = ""
    }

    private func removePattern(_ pattern: String) {
        appState.compressionSettings.exclusionPatterns.removeAll { $0 == pattern }
    }
}

#Preview {
    CompressionSettingsView()
        .environment(AppState())
        .environment(ProgressState())
}
