import SwiftUI
import BentoZipCore

/// Finder-style bottom Status Bar with zero middle dots.
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

    private var selectedEntriesSize: Int64 {
        appState.selectedEntries.reduce(0) { partial, entry in
            partial + entryTotalSize(entry)
        }
    }

    private var summaryText: String {
        let count = appState.displayedEntries.count
        if !appState.selectedEntryIDs.isEmpty {
            let selectedSize = Self.byteFormatter.string(fromByteCount: selectedEntriesSize)
            return String(localized: "\(appState.selectedEntryIDs.count) of \(count) selected, \(selectedSize)")
        }
        return String(localized: "\(count) items, \(formattedTotalSize)")
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

    private func entryTotalSize(_ entry: FileEntry) -> Int64 {
        if entry.isFromArchive, entry.isDirectory, let children = entry.children {
            return children.reduce(0) { $0 + entryTotalSize($1) }
        }
        return entry.size
    }
}
