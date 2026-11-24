import AppKit
import BentoZipCore
import SwiftUI

struct ProgressWindowView: View {
    @Environment(ProgressState.self) private var progressState

    private var clampedProgress: Double {
        min(max(progressState.operationProgress, 0.0), 1.0)
    }

    private var percentageText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(progressState.operationDescription.isEmpty ? String(localized: "Processing…") : progressState.operationDescription)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(percentageText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.10))

                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(0, proxy.size.width * clampedProgress))
                                .animation(.linear(duration: 0.08), value: clampedProgress)
                        }
                    }
                    .frame(height: 5)

                    if progressState.isCancellable {
                        Button {
                            progressState.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text("Cancel"))
                        .help("Cancel")
                    }
                }

                Text(progressState.currentFileName.isEmpty ? String(localized: "Preparing…") : progressState.currentFileName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
    }
}
