import BentoZipCore
import SwiftUI

/// Finder-style bottom Status Bar.
struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private var formattedTotalSize: String {
        Self.byteFormatter.string(fromByteCount: appState.totalSize)
    }

    private var selectedNodesSize: Int64 {
        _ = appState.nodeUpdateRevision
        let selectedIDs = appState.selectedEntryIDs
        return appState.selectedNodes.reduce(Int64(0)) { total, node in
            var ancestor = node.parent
            while let current = ancestor {
                if selectedIDs.contains(current.id) {
                    return total
                }
                ancestor = current.parent
            }
            return total + node.archiveTotalSize
        }
    }

    private var summaryText: String {
        let displayedNodes = appState.displayedNodes
        let displayedCount = displayedNodes.count
        let selectedNodes = appState.selectedNodes
        if !selectedNodes.isEmpty {
            let selectedSize = Self.byteFormatter.string(fromByteCount: selectedNodesSize)
            let displayedIDs = Set(displayedNodes.map(\.id))
            let allSelectedAreTopLevel = selectedNodes.allSatisfy { displayedIDs.contains($0.id) }
            if allSelectedAreTopLevel {
                return String(localized: "\(selectedNodes.count) of \(displayedCount) selected, \(selectedSize)")
            }
            return String(localized: "\(selectedNodes.count) selected, \(selectedSize)")
        }
        return String(localized: "\(displayedCount) items, \(formattedTotalSize)")
    }

    private var packedSummaryText: String? {
        guard appState.mode == .browseArchive,
              let packed = appState.totalPackedSize,
              packed > 0 else {
            return nil
        }
        let packedStr = Self.byteFormatter.string(fromByteCount: packed)
        if appState.totalSize > 0 && packed <= appState.totalSize {
            let ratio = Int(((Double(appState.totalSize - packed) / Double(appState.totalSize)) * 100).rounded())
            return String(localized: "Packed \(packedStr) (\(ratio)% saved)")
        }
        return String(localized: "Packed \(packedStr)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 10) {
                Text(summaryText)
                    .monospacedDigit()

                Spacer(minLength: 12)

                if let packedSummary = packedSummaryText {
                    Text(packedSummary)
                        .monospacedDigit()
                }

                if appState.mode == .browseArchive && appState.isArchiveEncrypted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Encrypted")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 23)
            .background(.bar)
        }
    }
}
