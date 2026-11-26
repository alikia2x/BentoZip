import AppKit
import BentoZipCore
import Foundation
import UniformTypeIdentifiers

@MainActor
enum FileKindCache {
    private static var cache: [String: String] = [:]

    static func localizedKind(for node: FileNode) -> String {
        localizedKind(isDirectory: node.isDirectory, pathExtension: node.url.pathExtension)
    }

    static func localizedKind(for entry: FileEntry) -> String {
        localizedKind(isDirectory: entry.isDirectory, pathExtension: entry.url.pathExtension)
    }

    private static func localizedKind(isDirectory: Bool, pathExtension: String) -> String {
        if isDirectory {
            return String(localized: "Folder")
        }
        let ext = pathExtension.lowercased()
        if ext.isEmpty {
            return String(localized: "Document")
        }
        if let cached = cache[ext] {
            return cached
        }
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        cache[ext] = kind
        return kind
    }
}

@MainActor
enum FileListFormatters {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

@MainActor
enum FileListTreeSupport {
    static func sortNodes(_ nodes: [FileNode], using descriptor: NSSortDescriptor?) -> [FileNode] {
        guard nodes.count > 1 else { return nodes }
        let key = descriptor?.key ?? "name"
        let ascending = descriptor?.ascending ?? true

        if key == "name" {
            let folders = nodes.filter(\.isDirectory).sorted { lhs, rhs in
                compareNames(lhs, rhs, ascending: ascending)
            }
            let files = nodes.filter { !$0.isDirectory }.sorted { lhs, rhs in
                compareNames(lhs, rhs, ascending: ascending)
            }
            return folders + files
        }

        return nodes.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case "date":
                let lDate = lhs.modificationDate ?? .distantPast
                let rDate = rhs.modificationDate ?? .distantPast
                comparison = lDate.compare(rDate)
            case "size":
                let lSize = lhs.isDirectory && lhs.size <= 0 ? -1 : lhs.size
                let rSize = rhs.isDirectory && rhs.size <= 0 ? -1 : rhs.size
                comparison = compareInt64(lSize, rSize)
            case "packed":
                let lPacked = lhs.isDirectory ? -1 : (lhs.packedSize ?? -1)
                let rPacked = rhs.isDirectory ? -1 : (rhs.packedSize ?? -1)
                comparison = compareInt64(lPacked, rPacked)
            case "ratio":
                let lRatio = savedRatioBasisPoints(for: lhs)
                let rRatio = savedRatioBasisPoints(for: rhs)
                comparison = compareInt64(lRatio, rRatio)
            case "crc":
                let lCrc = lhs.isDirectory ? -1 : lhs.crc.map(Int64.init) ?? -1
                let rCrc = rhs.isDirectory ? -1 : rhs.crc.map(Int64.init) ?? -1
                comparison = compareInt64(lCrc, rCrc)
            case "kind":
                let lKind = FileKindCache.localizedKind(for: lhs)
                let rKind = FileKindCache.localizedKind(for: rhs)
                comparison = lKind.localizedStandardCompare(rKind)
            default:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            }

            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
    }

    static func handleExtractionError(
        _ error: Error,
        appState: AppState,
        retryAction: PendingPasswordAction? = nil
    ) {
        if let bentoError = error as? Bento7zError,
           bentoError == .passwordRequired || bentoError == .wrongPassword {
            if bentoError == .wrongPassword {
                appState.archivePassword = nil
            }
            appState.pendingPasswordArchiveURL = appState.sourceArchiveURL
            appState.pendingPasswordAction = retryAction ?? appState.sourceArchiveURL.map { .browse($0) }
            appState.isPasswordRetryError = (bentoError == .wrongPassword)
            appState.passwordPromptReason = bentoError.localizedDescription
            appState.needsPasswordPrompt = true
        } else {
            appState.lastError = error.localizedDescription
        }
    }

    private static func compareNames(_ lhs: FileNode, _ rhs: FileNode, ascending: Bool) -> Bool {
        let result = lhs.name.localizedStandardCompare(rhs.name)
        return ascending ? (result == .orderedAscending) : (result == .orderedDescending)
    }

    private static func compareInt64(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func savedRatioBasisPoints(for node: FileNode) -> Int64 {
        guard !node.isDirectory, node.size > 0, let packed = node.packedSize, packed >= 0 else {
            return -1
        }
        guard packed <= node.size else { return 0 }
        return Int64(((Double(node.size - packed) / Double(node.size)) * 10_000.0).rounded())
    }
}
