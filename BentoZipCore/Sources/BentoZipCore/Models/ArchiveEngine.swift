import Foundation

public protocol ArchiveEngine {
    func listEntries(in archiveURL: URL) async throws -> [FileEntry]
    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws
    func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping (Double) -> Void
    ) async throws
    func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws
    func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping (Double) -> Void
    ) async throws
}
