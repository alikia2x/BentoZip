import BentoZipCore
import SwiftUI

struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentSubfolderPath: String
    let onCreate: (String) -> Void

    @State private var folderName: String = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if trimmedName.isEmpty {
            return nil
        }
        if trimmedName.contains("/") || trimmedName.contains("\\") || trimmedName.contains("\0") {
            return String(localized: "Folder name cannot contain slashes.")
        }
        if trimmedName == "." || trimmedName == ".." {
            return String(localized: "Invalid folder name.")
        }
        return nil
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("New Folder")
                        .font(.system(size: 14, weight: .semibold))

                    if !currentSubfolderPath.isEmpty {
                        Text(currentSubfolderPath)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            TextField("", text: $folderName, prompt: Text("Folder Name"))
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
                    submit()
                }

            if let validationError {
                Text(validationError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
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
            folderName = ""
            isNameFocused = true
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let name = trimmedName
        dismiss()
        onCreate(name)
    }
}
