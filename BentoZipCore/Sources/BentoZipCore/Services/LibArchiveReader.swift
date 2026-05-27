import Foundation
import libarchive

public struct LibArchiveReader: ArchiveEngine {
    public init() {}

    // MARK: - Errors

    public enum ReaderError: LocalizedError {
        case archiveCreateFailed
        case openFailed(String)
        case readFailed(String)
        case entryNotFound(String)
        case extractFailed(String)

        public var errorDescription: String? {
            switch self {
            case .archiveCreateFailed: return "Failed to create archive reader"
            case .openFailed(let d): return "Failed to open archive: \(d)"
            case .readFailed(let d): return "Failed to read archive: \(d)"
            case .entryNotFound(let p): return "Entry not found in archive: \(p)"
            case .extractFailed(let d): return "Failed to extract entry: \(d)"
            }
        }
    }

    // MARK: - listEntries

    public func listEntries(in archiveURL: URL) async throws -> [FileEntry] {
        guard let archive = archive_read_new() else {
            throw ReaderError.archiveCreateFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let openResult = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard openResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ReaderError.openFailed(err)
        }

        var entries: [FileEntry] = []

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ReaderError.readFailed(err)
            }

            // Copy C strings immediately (pointer is invalid after next call)
            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let size = archive_entry_size(entry)
            let filetype = archive_entry_filetype(entry)
            let isDir = (filetype & 0o170000) == 0o040000
            let mtime = archive_entry_mtime(entry)
            let mtimeNSec = archive_entry_mtime_nsec(entry)
            let modDate: Date? = mtime > 0
                ? Date(timeIntervalSince1970: TimeInterval(mtime) + TimeInterval(mtimeNSec) / 1_000_000_000)
                : nil

            let name = (pathname as NSString).lastPathComponent
            let archiveBase = URL(fileURLWithPath: "/archive-root/").appendingPathComponent(pathname)

            let fileEntry = FileEntry(
                url: archiveBase,
                name: name.isEmpty ? pathname : name,
                isDirectory: isDir,
                size: Int64(size),
                modificationDate: modDate,
                isFromArchive: true
            )
            entries.append(fileEntry)

            archive_read_data_skip(archive)
        }

        // Build directory hierarchy from flat path list
        return buildTree(from: entries)
    }

    private func buildTree(from entries: [FileEntry]) -> [FileEntry] {
        var flatEntries: [ArchiveTreeBuilder.FlatEntry] = []

        for entry in entries {
            let path = entry.url.path
            let relativePath: String
            if path.hasPrefix("/archive-root/") {
                relativePath = String(path.dropFirst("/archive-root/".count))
            } else if path.hasPrefix("/") {
                relativePath = String(path.dropFirst())
            } else {
                relativePath = path
            }

            guard !relativePath.isEmpty else { continue }

            let name = entry.name.isEmpty ? (relativePath as NSString).lastPathComponent : entry.name

            flatEntries.append(ArchiveTreeBuilder.FlatEntry(
                path: relativePath,
                name: name,
                isDirectory: entry.isDirectory,
                size: entry.size,
                modificationDate: entry.modificationDate
            ))
        }

        return ArchiveTreeBuilder.build(from: flatEntries)
    }

    // MARK: - extract

    public func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let entryPaths: Set<String>?
        if let entries = entries {
            entryPaths = Set(entries.map { extractPath(from: $0) })
        } else {
            entryPaths = nil
        }

        let totalEntries = try countEntries(in: archiveURL, matching: entryPaths)

        guard let archive = archive_read_new() else {
            throw ReaderError.archiveCreateFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let openResult = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard openResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ReaderError.openFailed(err)
        }

        var extractedCount: Int64 = 0

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else { continue }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""

            if let entryPaths = entryPaths, !entryPaths.contains(pathname) {
                archive_read_data_skip(archive)
                continue
            }

            let destPath = destinationURL.appendingPathComponent(pathname).path

            let parentDir = (destPath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parentDir) {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            }

            archive_entry_set_pathname(entry, destPath)

            let extractResult = archive_read_extract(archive, entry,
                ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_UNLINK)
            if extractResult != ARCHIVE_OK {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ReaderError.extractFailed(err)
            }

            extractedCount += 1
            if totalEntries > 0 {
                progress(Double(extractedCount) / Double(totalEntries))
            }
        }

        progress(1.0)
    }

    // MARK: - extractEntry

    public func extractEntry(from archiveURL: URL, entryPath: String, to destinationURL: URL) async throws {
        let fm = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard let archive = archive_read_new() else {
            throw ReaderError.archiveCreateFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let openResult = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard openResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ReaderError.openFailed(err)
        }

        var found = false

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else { continue }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            if pathname == entryPath {
                found = true
                archive_entry_set_pathname(entry, destinationURL.path)

                let extractResult = archive_read_extract(archive, entry,
                    ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME)
                if extractResult != ARCHIVE_OK {
                    let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                    throw ReaderError.extractFailed(err)
                }
                break
            } else {
                archive_read_data_skip(archive)
            }
        }

        guard found else {
            throw ReaderError.entryNotFound(entryPath)
        }
    }

    // MARK: - detectFormat

    public static func detectFormat(of url: URL) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tarGz
        }
        switch ext {
        case "zip": return .zip
        case "7z": return .sevenZip
        case "gz": return .tarGz
        default: break
        }

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 8) {
                if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
                    return .zip
                }
                if data.count >= 4 && data[0] == 0x37 && data[1] == 0x7A && data[2] == 0xBC && data[3] == 0xAF {
                    return .sevenZip
                }
                if data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B {
                    return .tarGz
                }
            }
        }

        return nil
    }

    // MARK: - create (unsupported)

    public func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping (Double) -> Void
    ) async throws {
        throw ReaderError.readFailed("Creation not supported by LibArchiveReader. Use LibArchiveWriter.")
    }

    // MARK: - removeEntries (unsupported — delegate to LibArchiveWriter)

    public func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws {
        throw ReaderError.readFailed("Removal not supported by LibArchiveReader. Use LibArchiveWriter.")
    }

    // MARK: - addEntries (unsupported — delegate to LibArchiveWriter)

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping (Double) -> Void
    ) async throws {
        throw ReaderError.readFailed("Addition not supported by LibArchiveReader. Use LibArchiveWriter.")
    }

    // MARK: - Private helpers

    private func countEntries(in archiveURL: URL, matching entryPaths: Set<String>?) throws -> Int64 {
        guard let archive = archive_read_new() else {
            throw ReaderError.archiveCreateFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let openResult = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard openResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ReaderError.openFailed(err)
        }

        var count: Int64 = 0
        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else { continue }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            if entryPaths == nil || entryPaths?.contains(pathname) == true {
                count += 1
            }
            archive_read_data_skip(archive)
        }

        return count
    }

    /// Extract the relative archive path from a FileEntry.
    private func extractPath(from entry: FileEntry) -> String {
        let fullPath = entry.url.path
        // Strip "/archive-root/" prefix if present
        if fullPath.hasPrefix("/archive-root/") {
            return String(fullPath.dropFirst("/archive-root/".count))
        }
        return fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
    }
}
