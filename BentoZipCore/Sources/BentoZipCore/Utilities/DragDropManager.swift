import Foundation

/// Coordinates drag-out extraction of archive entries to temporary local URLs.
@MainActor
public final class DragDropManager {
    public static let shared = DragDropManager()

    private let sessionTempDir: URL
    private var extractedFiles: [String: URL] = [:]
    private let engine = Bento7zEngine()

    private init() {
        sessionTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoZip-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
    }

    /// Prepare a local URL for dragging an entry out of the window, propagating backend or path errors.
    /// For archive entries, extracts only the requested entry to a session temp folder.
    public func prepareForDragThrowing(
        _ entry: FileEntry,
        sourceArchiveURL: URL?,
        password: String? = nil
    ) async throws -> URL? {
        if !entry.isFromArchive {
            return entry.url
        }

        guard let archiveURL = sourceArchiveURL else {
            return nil
        }

        let safeName = try sanitizedEntryFileName(entry.name)
        let archivePath = entry.archiveRelativePath ?? extractArchivePath(from: entry)
        let cacheKey = "\(archiveURL.path)|\(archivePath)"
        if let cached = extractedFiles[cacheKey],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let proposedURL = sessionTempDir.appendingPathComponent(safeName)
        let basePath = sessionTempDir.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard proposedURL.standardizedFileURL.path.hasPrefix(basePrefix) else {
            throw Bento7zError.operationFailed("拖放目标路径越界: \(entry.name)", "INVALID_PATH")
        }

        let tempURL = PathUtils.uniqueFileURL(for: proposedURL)
        try await engine.extractEntry(
            from: archiveURL,
            entryPath: archivePath,
            to: tempURL,
            password: password
        )
        extractedFiles[cacheKey] = tempURL
        return tempURL
    }

    /// Prepare a local URL for dragging an entry out of the window.
    /// Returns `nil` when preparation fails (for throwing callers, use `prepareForDragThrowing`).
    public func prepareForDrag(
        _ entry: FileEntry,
        sourceArchiveURL: URL?,
        password: String? = nil
    ) async -> URL? {
        try? await prepareForDragThrowing(
            entry,
            sourceArchiveURL: sourceArchiveURL,
            password: password
        )
    }

    /// Remove temporary files extracted during drag-out operations.
    public func cleanup() {
        try? FileManager.default.removeItem(at: sessionTempDir)
        extractedFiles.removeAll()
        try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
    }

    private func sanitizedEntryFileName(_ name: String) throws -> String {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".." else {
            throw Bento7zError.operationFailed("非法拖放文件名: \(name)", "INVALID_PATH")
        }
        return trimmed
    }

    private func extractArchivePath(from entry: FileEntry) -> String {
        let fullPath = entry.url.path
        if fullPath.hasPrefix("/archive-root/") {
            return String(fullPath.dropFirst("/archive-root/".count))
        }
        return fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
    }
}
