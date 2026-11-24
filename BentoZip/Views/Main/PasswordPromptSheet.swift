import BentoZipCore
import SwiftUI

struct PasswordPromptSheet: View {
    @Environment(AppState.self) private var appState
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    @FocusState private var isPasswordFocused: Bool

    var onSubmit: ((String) async -> Void)? = nil

    private var archiveName: String {
        (appState.pendingPasswordArchiveURL ?? appState.sourceArchiveURL)?.lastPathComponent ?? String(localized: "Archive")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(archiveName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if appState.isPasswordRetryError {
                Text("Incorrect password, please try again")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 4) {
                Group {
                    if showPassword {
                        TextField("", text: $password, prompt: Text("Enter Password"))
                    } else {
                        SecureField("", text: $password, prompt: Text("Enter Password"))
                    }
                }
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isPasswordFocused)
                .onSubmit {
                    submit()
                }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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

            HStack(spacing: 8) {
                Spacer()

                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Cancel") {
                    appState.cancelPasswordPrompt()
                }
                .keyboardShortcut(.cancelAction)

                Button("Unlock") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || appState.isLoading)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 340)
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
}
