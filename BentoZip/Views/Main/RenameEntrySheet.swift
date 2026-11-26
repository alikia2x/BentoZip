import AppKit
import BentoZipCore
import SwiftUI

struct RenameEntrySheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: FileEntry
    let onRename: (String) -> Void

    @State private var nameInput: String = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if trimmedName.isEmpty {
            return nil
        }
        if trimmedName.contains("/") || trimmedName.contains("\\") || trimmedName.contains("\0") {
            return String(localized: "Name cannot contain slashes.")
        }
        if trimmedName == "." || trimmedName == ".." {
            return String(localized: "Invalid item name.")
        }
        return nil
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && trimmedName != entry.name && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: FileIconCache.icon(for: entry))
                    .resizable()
                    .frame(width: 24, height: 24)

                Text("Rename Item")
                    .font(.system(size: 14, weight: .semibold))
            }

            TextField("", text: $nameInput, prompt: Text("Item Name"))
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

                Button("Rename") {
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
            nameInput = entry.name
            isNameFocused = true
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let targetName = trimmedName
        dismiss()
        onRename(targetName)
    }
}
