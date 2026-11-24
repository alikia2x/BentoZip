import Foundation

/// Coordinates drag-out extraction of archive entries to temporary local URLs.
@MainActor
public final class DragDropManager {
    public static let shared = DragDropManager()

    private struct CacheKey: Hashable {
        let archivePath: String
        let modificationTimestamp: TimeInterval?
        let fileSize: Int64?
        let entryPath: String
    }

    private struct InFlightKey: Hashable {
        let cacheKey: CacheKey
        let password: String?
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<URL, Error>
    }

    private let sessionTempDir: URL
    private var extractedFiles: [CacheKey: URL] = [:]
    private var inFlightExtractions: [InFlightKey: InFlightEntry] = [:]
    private let engine = Bento7zEngine()

    private init() {
        sessionTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoZip-drag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
    }

    /// Prepare a local URL for dragging an entry out of the window, propagating backend or path errors.
    /// For archive entries, extracts only the requested entry into an isolated per-extraction subdirectory
    /// so concurrent requests (including entries sharing the same filename) never collide.
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
        let cacheKey = makeCacheKey(for: archiveURL, entryPath: archivePath)

        if let cached = extractedFiles[cacheKey],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let inFlightKey = InFlightKey(cacheKey: cacheKey, password: password)
        if let existing = inFlightExtractions[inFlightKey] {
            return try await existing.task.value
        }

        let extractionDir = sessionTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempURL = extractionDir.appendingPathComponent(safeName)
        let basePath = sessionTempDir.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard tempURL.standardizedFileURL.path.hasPrefix(basePrefix) else {
            throw Bento7zError.operationFailed(
                String(localized: "Drag destination escapes temporary directory: \(entry.name)", bundle: .module),
                "INVALID_PATH"
            )
        }

        let engine = self.engine
        let tokenID = UUID()
        let task = Task.detached(priority: .userInitiated) { () throws -> URL in
            try FileManager.default.createDirectory(at: extractionDir, withIntermediateDirectories: true)
            do {
                try await engine.extractEntry(
                    from: archiveURL,
                    entryPath: archivePath,
                    to: tempURL,
                    password: password
                )
                return tempURL
            } catch {
                try? FileManager.default.removeItem(at: extractionDir)
                throw error
            }
        }
        inFlightExtractions[inFlightKey] = InFlightEntry(id: tokenID, task: task)

        do {
            let extractedURL = try await task.value
            if inFlightExtractions[inFlightKey]?.id == tokenID {
                inFlightExtractions.removeValue(forKey: inFlightKey)
                extractedFiles[cacheKey] = extractedURL
            }
            return extractedURL
        } catch {
            if inFlightExtractions[inFlightKey]?.id == tokenID {
                inFlightExtractions.removeValue(forKey: inFlightKey)
            }
            throw error
        }
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

    /// Invalidate cached drag-out entries for `archiveURL` without deleting already-extracted files on disk
    /// so active Quick Look previews or drag operations in other windows remain intact.
    public func invalidateCache(for archiveURL: URL) {
        let targetPath = archiveURL.standardizedFileURL.path
        extractedFiles = extractedFiles.filter { key, _ in
            key.archivePath != targetPath
        }
        inFlightExtractions = inFlightExtractions.filter { key, _ in
            key.cacheKey.archivePath != targetPath
        }
    }

    /// Remove all temporary files extracted during drag-out operations (intended for app termination).
    public func cleanup() {
        for entry in inFlightExtractions.values {
            entry.task.cancel()
        }
        inFlightExtractions.removeAll()
        extractedFiles.removeAll()
        try? FileManager.default.removeItem(at: sessionTempDir)
        try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
    }

    private func makeCacheKey(for archiveURL: URL, entryPath: String) -> CacheKey {
        let standardizedPath = archiveURL.standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: standardizedPath)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value
        return CacheKey(
            archivePath: standardizedPath,
            modificationTimestamp: mtime,
            fileSize: fileSize,
            entryPath: entryPath
        )
    }

    private func sanitizedEntryFileName(_ name: String) throws -> String {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\0"),
              trimmed != ".",
              trimmed != ".." else {
            throw Bento7zError.operationFailed(
                String(localized: "Invalid drag item name: \(name)", bundle: .module),
                "INVALID_PATH"
            )
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
