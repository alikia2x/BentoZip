import AppKit
import BentoZipCore
import SwiftUI

struct UpdatePasswordSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(ProgressState.self) private var progressState
    @Environment(\.dismiss) private var dismiss

    @State private var newPassword: String = ""
    @State private var showPassword: Bool = false
    @State private var encryptionMethod: ZipEncryptionMethod = .aes256
    @State private var encryptHeaders: Bool = true
    @FocusState private var isPasswordFocused: Bool

    private var archiveFormat: ArchiveFormat? {
        appState.sourceArchiveURL.flatMap { FormatDetector.detectFormat(of: $0) }
    }

    private var isBusy: Bool {
        appState.isLoading || progressState.isOperationInProgress
    }

    private var canSubmit: Bool {
        guard !isBusy else { return false }
        if newPassword.isEmpty {
            return appState.isArchiveEncrypted
        }
        return true
    }

    private var titleText: String {
        appState.isArchiveEncrypted
            ? String(localized: "Change Password")
            : String(localized: "Set Password")
    }

    private var submitButtonTitle: String {
        if newPassword.isEmpty {
            return String(localized: "Remove Password")
        }
        return appState.isArchiveEncrypted
            ? String(localized: "Update")
            : String(localized: "Set Password")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let archiveURL = appState.sourceArchiveURL {
                    Image(nsImage: FileIconCache.icon(forFileAt: archiveURL.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }

                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            TextField("", text: $newPassword, prompt: Text("New Password"))
                        } else {
                            SecureField("", text: $newPassword, prompt: Text("New Password"))
                        }
                    }
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isPasswordFocused)
                    .onSubmit {
                        if canSubmit { submit() }
                    }

                    Button {
                        let generated = PasswordGenerator.generate()
                        newPassword = generated
                        showPassword = true
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generated, forType: .string)
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Generate Strong Password")

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
                    .help(showPassword ? "Hide Password" : "Show Password")
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

                Text("Leave blank to remove password.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if !newPassword.isEmpty {
                if archiveFormat == .zip {
                    Picker("Encryption", selection: $encryptionMethod) {
                        ForEach(ZipEncryptionMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                } else if archiveFormat == .sevenZip {
                    Toggle("Encrypt Filenames", isOn: $encryptHeaders)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(submitButtonTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isPasswordFocused = true
        }
    }

    private func submit() {
        let targetPassword: String? = newPassword.isEmpty ? nil : newPassword
        let method = encryptionMethod
        let encryptNames = encryptHeaders
        dismiss()
        Task {
            await appState.coordinator.updatePassword(
                appState: appState,
                newPassword: targetPassword,
                encryptionMethod: method,
                encryptHeaders: encryptNames,
                progressState: progressState
            )
        }
    }
}
