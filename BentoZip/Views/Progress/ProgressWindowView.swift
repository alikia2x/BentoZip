import AppKit
import SwiftUI
import BentoZipCore

struct ProgressWindowView: View {
    @Environment(ProgressState.self) private var progressState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    private var clampedProgress: Double {
        min(max(progressState.operationProgress, 0.0), 1.0)
    }

    private var percentageText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressState.operationDescription.isEmpty ? String(localized: "Processing…") : progressState.operationDescription)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(percentageText)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                HStack(spacing: 8) {
                    ProgressView(value: clampedProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .animation(.easeOut(duration: 0.14), value: clampedProgress)

                    if progressState.isCancellable {
                        Button {
                            progressState.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Cancel")
                    }
                }

                Text(progressState.currentFileName.isEmpty ? String(localized: "Preparing…") : progressState.currentFileName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 360)
        .background(.regularMaterial)
        .onAppear {
            scheduleDismissIfNeeded()
        }
        .task(id: progressState.shouldDismiss) {
            await performDismissIfNeeded()
        }
        .onDisappear {
            if progressState.isOperationInProgress {
                progressState.cancel()
            }
        }
    }

    private func scheduleDismissIfNeeded() {
        guard progressState.shouldDismiss else { return }
        Task { @MainActor in
            await performDismissIfNeeded()
        }
    }

    private func performDismissIfNeeded() async {
        guard progressState.shouldDismiss else { return }
        await Task.yield()
        guard !Task.isCancelled, progressState.shouldDismiss else { return }
        dismissWindow(id: "progress")
        dismiss()
        progressState.shouldDismiss = false
    }
}
