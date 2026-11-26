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

    private var isSearching: Bool {
        !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var contextUncompressedSize: Int64 {
        _ = appState.nodeUpdateRevision
        if isSearching {
            let displayedNodes = appState.displayedNodes
            let displayedIDs = Set(displayedNodes.map(\.id))
            return displayedNodes.reduce(Int64(0)) { total, node in
                var ancestor = node.parent
                while let current = ancestor {
                    if displayedIDs.contains(current.id) {
                        return total
                    }
                    ancestor = current.parent
                }
                return total + node.archiveTotalSize
            }
        }
        if appState.navigationNodeIDs.isEmpty {
            return appState.totalSize
        }
        return appState.currentFolderNodes.reduce(Int64(0)) { $0 + $1.archiveTotalSize }
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
            let currentNavID = appState.navigationNodeIDs.last
            let allSelectedAreTopLevel = selectedNodes.allSatisfy { $0.parent?.id == currentNavID }
            if allSelectedAreTopLevel {
                return String(localized: "\(selectedNodes.count) of \(displayedCount) selected, \(selectedSize)")
            }
            return String(localized: "\(selectedNodes.count) selected, \(selectedSize)")
        }
        if isSearching {
            switch displayedCount {
            case 0:
                return String(localized: "No matches")
            case 1:
                return String(localized: "1 match")
            default:
                return String(localized: "\(displayedCount) matches")
            }
        }
        let formattedContextSize = Self.byteFormatter.string(fromByteCount: contextUncompressedSize)
        return String(localized: "\(displayedCount) items, \(formattedContextSize)")
    }

    private var packedSummaryText: String? {
        guard appState.mode == .browseArchive,
              !isSearching,
              let packed = appState.currentFolderPackedSize,
              packed > 0 else {
            return nil
        }
        let uncompressed = contextUncompressedSize
        let packedStr = Self.byteFormatter.string(fromByteCount: packed)
        if uncompressed > 0 && packed <= uncompressed {
            let ratio = Int(((Double(uncompressed - packed) / Double(uncompressed)) * 100).rounded())
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
