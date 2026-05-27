import SwiftUI
import BentoZipCore

struct CompressionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newPattern: String = ""

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("基本设置") {
                Picker("格式", selection: $appState.compressionSettings.format) {
                    ForEach(ArchiveFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }

                Picker("压缩级别", selection: $appState.compressionSettings.compressionLevel) {
                    ForEach(CompressionLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }

                TextField("压缩包名称", text: $appState.compressionSettings.archiveName)
            }

            DisclosureGroup("高级选项") {
                Toggle("保留目录结构", isOn: $appState.compressionSettings.preserveDirectoryStructure)

                VStack(alignment: .leading, spacing: 8) {
                    Text("排除模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    List {
                        ForEach(appState.compressionSettings.exclusionPatterns.indices, id: \.self) { index in
                            HStack {
                                TextField("模式", text: patternBinding(for: index, appState: appState))
                                Button(action: {
                                    var settings = appState.compressionSettings
                                    settings.exclusionPatterns.remove(at: index)
                                    appState.compressionSettings = settings
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(appState.compressionSettings.exclusionPatterns.count) * 28 + 8, 120))

                    HStack {
                        TextField("新排除模式", text: $newPattern)
                        Button("添加") {
                            var settings = appState.compressionSettings
                            settings.exclusionPatterns.append(newPattern)
                            appState.compressionSettings = settings
                            newPattern = ""
                        }
                        .disabled(newPattern.isEmpty)
                    }
                }
                .padding(.top, 4)
            }

            Section("即将推出") {
                TextField("密码保护", text: .constant(""))
                    .disabled(true)
                TextField("分卷大小", text: .constant(""))
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func patternBinding(for index: Int, appState: AppState) -> Binding<String> {
        Binding(
            get: { appState.compressionSettings.exclusionPatterns[index] },
            set: {
                var settings = appState.compressionSettings
                settings.exclusionPatterns[index] = $0
                appState.compressionSettings = settings
            }
        )
    }
}

#Preview {
    CompressionSettingsView()
        .environment(AppState())
        .environment(ProgressState())
}
