import Foundation
import ZIPFoundation

public struct ZIPEngine: ArchiveEngine {
    public init() {}

    // MARK: - Compression Mapping

    /// Maps the app-level CompressionLevel to ZIPFoundation's CompressionMethod.
    private func zipCompressionMethod(from level: CompressionLevel) -> ZIPFoundation.CompressionMethod {
        switch level {
        case .none:
            return .none
        case .fast, .normal, .best:
            return .deflate
        }
    }

    // MARK: - ArchiveEngine Protocol

    public func listEntries(in archiveURL: URL) async throws -> [FileEntry] {
        let archive = try Archive(url: archiveURL, accessMode: .read)

        var flatEntries: [ArchiveTreeBuilder.FlatEntry] = []
        for entry in archive {
            // Remove trailing slash from directory paths (ZIP convention)
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let name = (path as NSString).lastPathComponent
            let isDir = entry.type == .directory

            flatEntries.append(ArchiveTreeBuilder.FlatEntry(
                path: path,
                name: name,
                isDirectory: isDir,
                size: Int64(entry.uncompressedSize),
                modificationDate: entry.fileAttributes[.modificationDate] as? Date
            ))
        }

        return ArchiveTreeBuilder.build(from: flatEntries)
    }

    public func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)

        let entriesToExtract: [Entry]
        if let requestedEntries = entries {
            let entryNames = Set(requestedEntries.map { $0.name })
            entriesToExtract = archive.filter { entryNames.contains($0.path) }
        } else {
            entriesToExtract = Array(archive)
        }

        let total = entriesToExtract.count
        guard total > 0 else {
            progress(1.0)
            return
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: destinationURL.path) {
            try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }

        for (index, entry) in entriesToExtract.enumerated() {
            try archive.extract(entry, to: destinationURL)
            progress(Double(index + 1) / Double(total))
        }
    }

    public func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            progress(1.0)
            return
        }

        let compressionMethod = zipCompressionMethod(from: settings.compressionLevel)
        let fm = FileManager.default

        // Ensure parent directory exists
        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        if sourceURLs.count == 1 {
            // Single source: use FileManager.zipItem (handles directory recursion natively)
            let source = sourceURLs[0]
            try fm.zipItem(
                at: source,
                to: archiveURL,
                shouldKeepParent: settings.preserveDirectoryStructure,
                compressionMethod: compressionMethod
            )
            progress(1.0)
        } else {
            // Multiple sources: build archive entry-by-entry
            var archive = try Archive(url: archiveURL, accessMode: .create)
            let total = sourceURLs.count

            for (index, source) in sourceURLs.enumerated() {
                let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir {
                    try addDirectory(
                        to: &archive,
                        directoryURL: source,
                        compressionMethod: compressionMethod,
                        exclusionPatterns: settings.exclusionPatterns
                    )
                } else {
                    try archive.addEntry(
                        with: source.lastPathComponent,
                        relativeTo: source.deletingLastPathComponent(),
                        compressionMethod: compressionMethod
                    )
                }

                progress(Double(index + 1) / Double(total))
            }
        }
    }

    public func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let fm = FileManager.default

        let entryNamesToRemove = Set(entries.map { $0.name })
        let remainingEntries = archive.filter { !entryNamesToRemove.contains($0.path) }

        // If no entries remain, just delete the archive
        guard !remainingEntries.isEmpty else {
            try fm.removeItem(at: archiveURL)
            return
        }

        let tempURL = archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(".temp_" + archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempURL) }

        var newArchive = try Archive(url: tempURL, accessMode: .create)
        let extractDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: extractDir) }
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        for entry in remainingEntries where entry.type == .file {
            try archive.extract(entry, to: extractDir)
            try newArchive.addEntry(
                with: entry.path,
                relativeTo: extractDir,
                compressionMethod: .none
            )
        }

        // Replace original archive with the filtered one
        try fm.removeItem(at: archiveURL)
        try fm.moveItem(at: tempURL, to: archiveURL)
    }

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            progress(1.0)
            return
        }

        var archive = try Archive(url: archiveURL, accessMode: .update)
        let total = sourceURLs.count

        for (index, source) in sourceURLs.enumerated() {
            try archive.addEntry(
                with: source.lastPathComponent,
                relativeTo: source.deletingLastPathComponent(),
                compressionMethod: .deflate
            )
            progress(Double(index + 1) / Double(total))
        }
    }

    // MARK: - Private Helpers

    /// Recursively adds all files from a directory into the archive.
    /// Directory entries are implicit via file paths; excluded patterns skip both files and subdirectories.
    private func addDirectory(
        to archive: inout Archive,
        directoryURL: URL,
        compressionMethod: CompressionMethod,
        exclusionPatterns: [String]
    ) throws {
        let fm = FileManager.default
        let dirName = directoryURL.lastPathComponent

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let parentOfSource = directoryURL.deletingLastPathComponent()

        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            guard let isDirectory = values.isDirectory, let name = values.name else { continue }

            // Skip entries matching exclusion patterns
            let excluded = exclusionPatterns.contains { pattern in
                name == pattern || fileURL.path.hasSuffix("/" + pattern)
            }
            if excluded {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            guard !isDirectory else { continue }

            // Build path inside the archive: dirName/sub/path/file.ext
            let relativeToDir = fileURL.path.replacingOccurrences(
                of: directoryURL.path + "/",
                with: ""
            )
            let entryPath = dirName + "/" + relativeToDir

            try archive.addEntry(
                with: entryPath,
                relativeTo: parentOfSource,
                compressionMethod: compressionMethod
            )
        }
    }
}
