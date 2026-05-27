import Foundation

@MainActor
final class DragDropManager {
    static let shared = DragDropManager()

    private let sessionTempDir: URL
    private var extractedFiles: [String: URL] = [:]

    private init() {
        sessionTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoZip-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
    }

    func prepareForDrag(_ entry: FileEntry, sourceArchiveURL: URL?) async -> URL? {
        if !entry.isFromArchive {
            return entry.url
        }

        if let cached = extractedFiles[entry.id.uuidString] {
            return cached
        }

        let reader = LibArchiveReader()
        let tempURL = sessionTempDir.appendingPathComponent(entry.name)

        do {
            if let archiveURL = sourceArchiveURL {
                let archivePath = extractArchivePath(from: entry)
                try await reader.extractEntry(from: archiveURL, entryPath: archivePath, to: tempURL)
                extractedFiles[entry.id.uuidString] = tempURL
                return tempURL
            }
        } catch {
            return nil
        }

        return nil
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sessionTempDir)
        extractedFiles.removeAll()
    }

    private func extractArchivePath(from entry: FileEntry) -> String {
        let fullPath = entry.url.path
        if fullPath.hasPrefix("/archive-root/") {
            return String(fullPath.dropFirst("/archive-root/".count))
        }
        return fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
    }
}
