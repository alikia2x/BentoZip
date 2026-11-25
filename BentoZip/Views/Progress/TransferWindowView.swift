import AppKit
import BentoZipCore
import SwiftUI

/// Content view hosted inside the standalone Progress window.
/// Stacks concurrent tasks vertically with fixed non-jumping spacing and an expandable 7-Zip-style stats drawer.
struct TransferWindowView: View {
    let transferManager: TransferManager

    var body: some View {
        Group {
            if transferManager.tasks.isEmpty {
                VStack(spacing: 6) {
                    Text("No Active Tasks")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 400, height: 72)
            } else if transferManager.tasks.count > 3 {
                ScrollView(.vertical) {
                    taskList
                }
                .frame(width: 400, height: 340)
            } else {
                taskList
                    .frame(width: 400)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            ForEach(Array(transferManager.tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 {
                    Divider()
                }
                TransferTaskRowView(task: task)
            }
        }
    }
}

private struct TransferTaskRowView: View {
    let task: TransferTask
    @State private var isExpanded = false

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var clampedProgress: Double {
        min(max(task.fractionCompleted, 0.0), 1.0)
    }

    private var percentageText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 5) {
                    // Row 1: Operation title + percentage (fixed 16pt height)
                    HStack(alignment: .center, spacing: 8) {
                        Text(task.title.isEmpty ? String(localized: "Processing…") : task.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        Text(percentageText)
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 16)

                    // Row 2: Native linear ProgressView + constant-slot cancel button (fixed 16pt height at all stages)
                    HStack(alignment: .center, spacing: 8) {
                        ProgressView(value: clampedProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .labelsHidden()
                            .controlSize(.small)

                        Button {
                            task.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(!task.isCancellable)
                        .opacity(task.isCancellable ? 1.0 : 0.25)
                        .accessibilityLabel(Text("Cancel"))
                        .help("Cancel")
                    }
                    .frame(height: 16)

                    // Row 3: Current filename + right-side details disclosure chevron (fixed 16pt height)
                    HStack(alignment: .center, spacing: 8) {
                        Text(task.currentFileName.isEmpty ? String(localized: "Preparing…") : task.currentFileName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                .animation(.easeInOut(duration: 0.14), value: isExpanded)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .accessibilityLabel(Text(isExpanded ? "Hide Details" : "Show Details"))
                        .help(isExpanded ? "Hide Details" : "Show Details")
                    }
                    .frame(height: 16)
                }
            }

            if isExpanded {
                Divider()
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                detailsGrid
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var detailsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    metricPair(label: "Elapsed", value: formatDuration(task.elapsedSeconds))
                    metricPair(label: "Remaining", value: task.estimatedRemainingSeconds.map(formatDuration) ?? "--")
                }

                GridRow {
                    metricPair(label: "Speed", value: formattedSpeed)
                    metricPair(label: "Processed", value: formattedBytesProgress)
                }

                GridRow {
                    metricPair(label: "Files", value: formattedFilesProgress)
                    if task.kind == .compress {
                        metricPair(label: "Compressed", value: formattedCompressedSummary)
                    } else {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }

            if let destinationPath = formattedDestinationPath {
                HStack(spacing: 6) {
                    Text("Destination")
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Text(destinationPath)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .padding(.top, 2)
            }
        }
    }

    private func metricPair(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize()

            Spacer(minLength: 4)

            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }

    private var formattedSpeed: String {
        guard task.bytesPerSecond >= 1 else { return "--" }
        let formatted = Self.byteFormatter.string(fromByteCount: Int64(task.bytesPerSecond.rounded()))
        return "\(formatted)/s"
    }

    private var formattedBytesProgress: String {
        if task.totalBytes > 0 {
            let done = Self.byteFormatter.string(fromByteCount: task.processedBytes)
            let total = Self.byteFormatter.string(fromByteCount: task.totalBytes)
            return "\(done) / \(total)"
        }
        if task.processedBytes > 0 {
            return Self.byteFormatter.string(fromByteCount: task.processedBytes)
        }
        return "--"
    }

    private var formattedFilesProgress: String {
        if let totalFiles = task.totalFiles, totalFiles > 0 {
            let current = min(task.processedFiles, totalFiles)
            return "\(current) / \(totalFiles)"
        }
        return task.processedFiles > 0 ? "\(task.processedFiles)" : "--"
    }

    private var formattedCompressedSummary: String {
        guard let compressed = task.compressedBytes, compressed > 0 else { return "--" }
        let sizeText = Self.byteFormatter.string(fromByteCount: compressed)
        if let ratio = task.compressionRatioPercent {
            return "\(sizeText) (\(ratio)%)"
        }
        return sizeText
    }

    private var formattedDestinationPath: String? {
        guard let url = task.destinationURL else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
