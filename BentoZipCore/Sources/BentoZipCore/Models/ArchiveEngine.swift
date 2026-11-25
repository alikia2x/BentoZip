import Foundation

/// Detailed progress update emitted by an archive engine during compress/extract operations.
public struct ArchiveProgress: Sendable, Equatable {
    public let fractionCompleted: Double
    public let currentFile: String?
    public let processedBytes: Int64?
    public let totalBytes: Int64?
    public let isFileEvent: Bool
    public let fileCountDelta: Int

    public init(
        fractionCompleted: Double,
        currentFile: String? = nil,
        processedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        isFileEvent: Bool = false,
        fileCountDelta: Int? = nil
    ) {
        self.fractionCompleted = fractionCompleted
        self.currentFile = currentFile
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.isFileEvent = isFileEvent
        self.fileCountDelta = fileCountDelta ?? (isFileEvent ? 1 : 0)
    }
}

/// Result of listing an archive's entries along with optional archive-level packed size.
public struct ArchiveListResult: Sendable, Equatable {
    public let entries: [FileEntry]
    public let archivePackedSize: Int64?

    public init(entries: [FileEntry], archivePackedSize: Int64? = nil) {
        self.entries = entries
        self.archivePackedSize = archivePackedSize
    }
}

/// Protocol implemented by archive backend engines.
public protocol ArchiveEngine: Sendable {
    func listEntries(in archiveURL: URL, password: String?) async throws -> [FileEntry]

    func listArchive(in archiveURL: URL, password: String?) async throws -> ArchiveListResult

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws

    func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws

    func removeEntries(from archiveURL: URL, entries: [FileEntry], password: String?) async throws

    func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws
}

public extension ArchiveEngine {
    func listEntries(in archiveURL: URL) async throws -> [FileEntry] {
        try await listEntries(in: archiveURL, password: nil)
    }

    func listArchive(in archiveURL: URL, password: String?) async throws -> ArchiveListResult {
        let entries = try await listEntries(in: archiveURL, password: password)
        return ArchiveListResult(entries: entries, archivePackedSize: nil)
    }

    func listArchive(in archiveURL: URL) async throws -> ArchiveListResult {
        try await listArchive(in: archiveURL, password: nil)
    }

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await extract(
            archiveURL: archiveURL,
            entries: entries,
            to: destinationURL,
            password: nil,
            onProgress: { progress($0.fractionCompleted) }
        )
    }

    func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await create(
            from: sourceURLs,
            to: archiveURL,
            settings: settings,
            onProgress: { progress($0.fractionCompleted) }
        )
    }

    func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws {
        try await removeEntries(from: archiveURL, entries: entries, password: nil)
    }

    func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await addEntries(
            to: archiveURL,
            from: sourceURLs,
            password: nil,
            onProgress: { progress($0.fractionCompleted) }
        )
    }
}
