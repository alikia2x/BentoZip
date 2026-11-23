import BentoZipCore
import SwiftUI

struct PasswordPromptSheet: View {
    @Environment(AppState.self) private var appState
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    @FocusState private var isPasswordFocused: Bool

    var onSubmit: ((String) async -> Void)? = nil

    private var archiveName: String {
        (appState.pendingPasswordArchiveURL ?? appState.sourceArchiveURL)?.lastPathComponent ?? "压缩包"
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 52, height: 52)

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text("输入密码以打开「\(archiveName)」")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(appState.passwordPromptReason ?? "此压缩包受密码保护，请输入密码以继续。")
                    .font(.callout)
                    .foregroundStyle(appState.isPasswordRetryError ? .red : .secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                Group {
                    if showPassword {
                        TextField("输入密码", text: $password)
                    } else {
                        SecureField("输入密码", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFocused)
                .onSubmit {
                    submit()
                }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showPassword ? "隐藏密码" : "显示密码")
            }

            HStack(spacing: 10) {
                Button("取消") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("解锁") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || appState.isLoading)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            password = ""
            isPasswordFocused = true
        }
        .onChange(of: appState.isPasswordRetryError) { _, isRetryError in
            if isRetryError {
                password = ""
                isPasswordFocused = true
            }
        }
    }

    private func submit() {
        guard !password.isEmpty, !appState.isLoading else { return }
        let entered = password
        Task {
            if let onSubmit {
                await onSubmit(entered)
            } else {
                await appState.coordinator.submitPassword(entered, appState: appState)
            }
            if appState.needsPasswordPrompt && appState.isPasswordRetryError {
                password = ""
                isPasswordFocused = true
            }
        }
    }

    private func cancel() {
        appState.cancelPasswordPrompt()
    }
}

#Preview {
    PasswordPromptSheet()
        .environment(AppState())
}
