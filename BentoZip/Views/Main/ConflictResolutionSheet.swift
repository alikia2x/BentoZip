import BentoZipCore
import SwiftUI

struct ConflictResolutionSheet: View {
    let prompt: ExtractConflictPrompt

    @State private var applyToAll: Bool = false

    private var destinationFolderName: String {
        let folder = prompt.destinationURL.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty ? prompt.destinationURL.deletingLastPathComponent().path : folder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 5) {
                    Text("An item named \"\(prompt.sourceName)\" already exists in \"\(destinationFolderName)\".")
                        .font(.system(size: 13.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(prompt.isDirectory
                         ? String(localized: "Do you want to replace the existing folder, keep both, or skip it?")
                         : String(localized: "Do you want to replace the existing file, keep both, or skip it?"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
                .font(.system(size: 12))
                .padding(.top, 2)

            HStack(spacing: 8) {
                Button("Cancel") {
                    prompt.cancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Skip") {
                    prompt.resolve(.skip, applyToAll: applyToAll)
                }

                Button("Keep Both") {
                    prompt.resolve(.rename, applyToAll: applyToAll)
                }

                Button("Replace") {
                    prompt.resolve(.overwrite, applyToAll: applyToAll)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(true)
        .onDisappear {
            prompt.cancel()
        }
    }
}
