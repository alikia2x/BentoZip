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
    @State private var newPattern: String = ""
    @State private var hasLoaded: Bool = false

    var body: some View {
        Form {
            Section("默认压缩参数") {
                Picker("默认格式", selection: $defaultFormat) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("默认压缩级别", selection: $defaultLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
            }

            Section("行为偏好") {
                Toggle("压缩或解压完成后在访达中显示", isOn: $revealInFinderAfterExtract)
                Toggle("解压时自动展开单一顶层文件夹", isOn: $unwrapSingleTopDirectory)
                    .help("当压缩包内仅包含一个顶层文件夹时，直接将其内容解压到目标文件夹中")
            }

            Section {
                if exclusionPatterns.isEmpty {
                    Text("暂无默认排除规则")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(exclusionPatterns, id: \.self) { pattern in
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(.secondary)
                            Text(pattern)
                                .font(.system(.body, design: .monospaced))
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
                            .help("移除规则")
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("添加规则（如 *.log、node_modules）", text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addPattern()
                        }

                    Button("添加") {
                        addPattern()
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("恢复默认") {
                        exclusionPatterns = [".DS_Store", "__MACOSX"]
                        persistChanges()
                    }
                    .disabled(exclusionPatterns == [".DS_Store", "__MACOSX"])
                }
            } header: {
                Text("默认排除规则")
            } footer: {
                Text("支持文件名或通配符模式，新建压缩任务时将自动应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
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

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !exclusionPatterns.contains(trimmed) {
            exclusionPatterns.append(trimmed)
            persistChanges()
        }
        newPattern = ""
    }

    private func removePattern(_ pattern: String) {
        exclusionPatterns.removeAll { $0 == pattern }
        persistChanges()
    }
}

#Preview {
    SettingsView(preferencesManager: PreferencesManager())
}
