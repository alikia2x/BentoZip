import SwiftUI
import BentoZipCore

struct ProgressWindowView: View {
    @Environment(ProgressState.self) private var progressState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow

    private var clampedProgress: Double {
        min(max(progressState.operationProgress, 0.0), 1.0)
    }

    private var operationIconName: String {
        let desc = progressState.operationDescription
        if desc.contains("压缩") {
            return "doc.zipper"
        } else if desc.contains("添加") {
            return "plus.circle.fill"
        } else if desc.contains("删除") {
            return "trash.fill"
        } else {
            return "tray.and.arrow.down.fill"
        }
    }

    private var percentageText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 48, height: 48)

                Image(systemName: operationIconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse, isActive: progressState.isOperationInProgress)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressState.operationDescription.isEmpty ? "正在处理..." : progressState.operationDescription)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(percentageText)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                ProgressView(value: clampedProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.smooth(duration: 0.15), value: clampedProgress)

                HStack(spacing: 8) {
                    Text(progressState.currentFileName.isEmpty ? "准备中..." : progressState.currentFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if progressState.isCancellable {
                        Button("取消") {
                            progressState.cancel()
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 400)
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

#Preview {
    let state = ProgressState()
    state.isOperationInProgress = true
    state.operationDescription = "正在压缩..."
    state.currentFileName = "very-long-archive-asset-name-for-preview.png"
    state.operationProgress = 0.64
    return ProgressWindowView()
        .environment(state)
}
