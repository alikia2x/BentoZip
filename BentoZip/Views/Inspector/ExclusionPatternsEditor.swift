import SwiftUI

struct ExclusionPatternsEditor: View {
    @Binding var patterns: [String]
    var showResetButton: Bool = false
    var onChanged: (() -> Void)? = nil

    @State private var newPattern: String = ""

    private static let defaultPatterns = [".DS_Store", "__MACOSX"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !patterns.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(patterns, id: \.self) { pattern in
                        HStack(spacing: 4) {
                            Text(pattern)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Button {
                                remove(pattern)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 7)
                        .padding(.trailing, 4)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.065))
                        )
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("", text: $newPattern, prompt: Text("*.log"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { add() }

                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if showResetButton {
                    Button("Reset") {
                        patterns = Self.defaultPatterns
                        onChanged?()
                    }
                    .controlSize(.small)
                    .disabled(patterns == Self.defaultPatterns)
                }
            }
        }
    }

    private func add() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !patterns.contains(trimmed) {
            patterns.append(trimmed)
            onChanged?()
        }
        newPattern = ""
    }

    private func remove(_ pattern: String) {
        patterns.removeAll { $0 == pattern }
        onChanged?()
    }
}
