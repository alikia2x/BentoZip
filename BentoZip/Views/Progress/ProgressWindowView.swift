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
        HStack(spacing: 11) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(progressState.operationDescription.isEmpty ? String(localized: "Processing…") : progressState.operationDescription)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(percentageText)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
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
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 356, height: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .background(ProgressWindowConfigurator(targetSize: NSSize(width: 356, height: 72)))
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

private struct ProgressWindowConfigurator: NSViewRepresentable {
    let targetSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        if window.styleMask.contains(.titled) {
            window.styleMask.remove(.titled)
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        if window.frame.size != targetSize {
            window.setContentSize(targetSize)
        }
    }
}
