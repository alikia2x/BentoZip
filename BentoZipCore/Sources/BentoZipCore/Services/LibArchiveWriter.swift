import Foundation
import libarchive

// MARK: - Errors

public enum ArchiveWriterError: LocalizedError {
    case archiveCreationFailed
    case formatSetupFailed(String)
    case filterSetupFailed(String)
    case openFailed(String)
    case headerWriteFailed(String)
    case dataWriteFailed(String)
    case closeFailed(String)
    case entryCreationFailed
    case extractionFailed(String)
    case noEntriesToArchive
    case fileReadFailed(URL, Error)

    public var errorDescription: String? {
        switch self {
        case .archiveCreationFailed:
            return "Failed to create archive writer."
        case .formatSetupFailed(let detail):
            return "Failed to set archive format: \(detail)"
        case .filterSetupFailed(let detail):
            return "Failed to set archive filter: \(detail)"
        case .openFailed(let detail):
            return "Failed to open archive for writing: \(detail)"
        case .headerWriteFailed(let detail):
            return "Failed to write archive entry header: \(detail)"
        case .dataWriteFailed(let detail):
            return "Failed to write archive entry data: \(detail)"
        case .closeFailed(let detail):
            return "Failed to close archive: \(detail)"
        case .entryCreationFailed:
            return "Failed to create archive entry."
        case .extractionFailed(let detail):
            return "Failed to extract archive: \(detail)"
        case .noEntriesToArchive:
            return "No entries to archive."
        case .fileReadFailed(let url, let error):
            return "Failed to read file at \(url.path): \(error.localizedDescription)"
        }
    }
}

// MARK: - LibArchiveWriter

public struct LibArchiveWriter: ArchiveEngine {
    public init() {}

    // MARK: - listEntries

    public func listEntries(in archiveURL: URL) async throws -> [FileEntry] {
        var entries: [FileEntry] = []
        guard let archive = archive_read_new() else {
            throw ArchiveWriterError.archiveCreationFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let result = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard result == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.openFailed(err)
        }

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let size = archive_entry_size(entry)
            let filetype = archive_entry_filetype(entry)
            let isDir = (filetype & 0o170000) == 0o040000
            let mtimeSec = archive_entry_mtime(entry)
            let mtimeNsec = archive_entry_mtime_nsec(entry)
            let modDate: Date? = mtimeSec > 0
                ? Date(timeIntervalSince1970: TimeInterval(mtimeSec) + TimeInterval(mtimeNsec) / 1_000_000_000)
                : nil

            let entryURL = URL(fileURLWithPath: "entries/\(pathname)") // placeholder URL
            let fileEntry = FileEntry(
                url: entryURL,
                name: (pathname as NSString).lastPathComponent,
                isDirectory: isDir,
                size: size,
                modificationDate: modDate,
                isFromArchive: true
            )
            entries.append(fileEntry)

            archive_read_data_skip(archive)
        }

        return entries
    }

    // MARK: - extract

    public func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let excludePaths: Set<String>?
        if let entries = entries, !entries.isEmpty {
            excludePaths = Set(entries.map { $0.name })
        } else {
            excludePaths = nil
        }

        let entryCount = try countEntriesForExtract(in: archiveURL, excludePaths: excludePaths)

        guard let archive = archive_read_new() else {
            throw ArchiveWriterError.archiveCreationFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let result = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard result == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.openFailed(err)
        }

        var extractedCount: Int64 = 0

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let name = (pathname as NSString).lastPathComponent

            if let excludePaths = excludePaths, excludePaths.contains(name) {
                archive_read_data_skip(archive)
                continue
            }

            let destPath = destinationURL.appendingPathComponent(pathname).path
            archive_entry_set_pathname(entry, destPath)

            let extractResult = archive_read_extract(archive, entry,
                ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_ACL)
            if extractResult != ARCHIVE_OK {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }

            extractedCount += 1
            if entryCount > 0 {
                progress(Double(extractedCount) / Double(entryCount))
            }
        }

        progress(1.0)
    }

    private func countEntriesForExtract(in archiveURL: URL, excludePaths: Set<String>?) throws -> Int64 {
        guard let archive = archive_read_new() else {
            throw ArchiveWriterError.archiveCreationFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let result = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard result == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.openFailed(err)
        }

        var count: Int64 = 0
        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK else {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }
            let pathname = archive_entry_pathname(entryPtr!).map { String(cString: $0) } ?? ""
            let name = (pathname as NSString).lastPathComponent
            if excludePaths == nil || !excludePaths!.contains(name) {
                count += 1
            }
            archive_read_data_skip(archive)
        }

        return count
    }

    // MARK: - create

    public func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        progress: @escaping (Double) -> Void
    ) async throws {
        // Collect all files to archive
        var fileEntries: [(sourcePath: String, archivePath: String, size: Int64, mtime: time_t, isDir: Bool)] = []

        try await collectFiles(
            from: sourceURLs,
            settings: settings,
            fileEntries: &fileEntries
        )

        guard !fileEntries.isEmpty else {
            throw ArchiveWriterError.noEntriesToArchive
        }

        // Compute total size for progress
        let totalSize = fileEntries.reduce(Int64(0)) { $0 + $1.size }
        var bytesWritten: Int64 = 0

        // Create and configure archive writer
        guard let archive = archive_write_new() else {
            throw ArchiveWriterError.archiveCreationFailed
        }
        defer { archive_write_free(archive) }

        // Set format
        let formatResult = configureFormat(archive, format: settings.format)
        guard formatResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.formatSetupFailed(err)
        }

        // Set filter (compression)
        let filterResult = configureFilter(archive, format: settings.format)
        guard filterResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.filterSetupFailed(err)
        }

        // Avoid 10240-byte trailing padding
        archive_write_set_bytes_in_last_block(archive, 1)

        // Open output file
        let openResult = archiveURL.path.withCString { path in
            archive_write_open_filename(archive, path)
        }
        guard openResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.openFailed(err)
        }

        // Write each entry
        for file in fileEntries {
            if file.isDir {
                // Write directory entry
                try writeDirectoryEntry(archive: archive, archivePath: file.archivePath, mtime: file.mtime)
            } else {
                // Write file entry with data
                let sourceURL = URL(fileURLWithPath: file.sourcePath)
                try writeFileEntry(
                    archive: archive,
                    sourceURL: sourceURL,
                    archivePath: file.archivePath,
                    size: file.size,
                    mtime: file.mtime
                )
                bytesWritten += file.size
            }

            if totalSize > 0 {
                progress(Double(bytesWritten) / Double(totalSize))
            }
        }

        // Close archive
        let closeResult = archive_write_close(archive)
        guard closeResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.closeFailed(err)
        }

        progress(1.0)
    }

    // MARK: - removeEntries

    public func removeEntries(from archiveURL: URL, entries: [FileEntry]) async throws {
        let fileManager = FileManager.default

        // Create temp directories
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BentoZip_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent("archive")

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Determine archive format by extension
        let format = detectFormat(from: archiveURL)

        // Extract all entries except those to remove
        let namesToRemove = Set(entries.map { $0.name })

        try await extractEntries(
            archiveURL: archiveURL,
            to: extractDir,
            excludeNames: namesToRemove
        )

        // Create new archive from extracted files
        let extractedContents = try fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard !extractedContents.isEmpty else {
            // Nothing left after removal - replace with empty temp file then delete
            try? fileManager.removeItem(at: archiveURL)
            return
        }

        let settings = CompressionSettings(format: format, archiveName: archiveURL.lastPathComponent)

        try await create(
            from: extractedContents,
            to: newArchiveURL,
            settings: settings,
            progress: { _ in }
        )

        // Atomic replace
        let backupURL = tempDir.appendingPathComponent("backup_archive")
        try fileManager.moveItem(at: archiveURL, to: backupURL)
        do {
            try fileManager.moveItem(at: newArchiveURL, to: archiveURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            // Rollback
            try? fileManager.removeItem(at: archiveURL)
            try fileManager.moveItem(at: backupURL, to: archiveURL)
            throw error
        }
    }

    // MARK: - addEntries

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        progress: @escaping (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default

        // Create temp directories
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BentoZip_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent("archive")

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Determine archive format by extension
        let format = detectFormat(from: archiveURL)

        // Extract ALL existing entries
        try await extractEntries(
            archiveURL: archiveURL,
            to: extractDir,
            excludeNames: []
        )

        // Copy new source files into the extract directory
        for sourceURL in sourceURLs {
            let destURL = extractDir.appendingPathComponent(sourceURL.lastPathComponent)
            if FileUtils.isDirectory(at: sourceURL) {
                try fileManager.copyItem(at: sourceURL, to: destURL)
            } else {
                // Ensure parent exists
                let parent = destURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }
        }

        // Create new archive
        let allContents = try fileManager.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)

        let settings = CompressionSettings(format: format, archiveName: archiveURL.lastPathComponent)

        try await create(
            from: allContents,
            to: newArchiveURL,
            settings: settings,
            progress: progress
        )

        // Atomic replace
        let backupURL = tempDir.appendingPathComponent("backup_archive")
        try fileManager.moveItem(at: archiveURL, to: backupURL)
        do {
            try fileManager.moveItem(at: newArchiveURL, to: archiveURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            // Rollback
            try? fileManager.removeItem(at: archiveURL)
            try fileManager.moveItem(at: backupURL, to: archiveURL)
            throw error
        }
    }

    // MARK: - Private Helpers

    /// Recursively collect files from sourceURLs, applying exclusion patterns.
    private func collectFiles(
        from sourceURLs: [URL],
        settings: CompressionSettings,
        basePath: String? = nil,
        fileEntries: inout [(sourcePath: String, archivePath: String, size: Int64, mtime: time_t, isDir: Bool)]
    ) async throws {
        let commonParent = PathUtils.commonParentDirectory(of: sourceURLs)

        for url in sourceURLs {
            let name = url.lastPathComponent

            // Skip excluded files
            if isExcluded(name: name, patterns: settings.exclusionPatterns) {
                continue
            }

            if FileUtils.isDirectory(at: url) {
                if settings.preserveDirectoryStructure {
                    // Determine archive path for this directory
                    let archiveDirPath: String
                    if let parent = commonParent {
                        let relPath = url.path.replacingOccurrences(of: parent.path + "/", with: "")
                        archiveDirPath = relPath.isEmpty ? name : relPath
                    } else {
                        archiveDirPath = name
                    }

                    fileEntries.append((
                        sourcePath: url.path,
                        archivePath: archiveDirPath,
                        size: 0,
                        mtime: time_t(FileUtils.fileModificationDate(at: url)?.timeIntervalSince1970 ?? 0),
                        isDir: true
                    ))

                    // Recurse into directory
                    let children = FileUtils.enumerateDirectory(at: url)
                    for child in children {
                        let childName = child.lastPathComponent
                        if isExcluded(name: childName, patterns: settings.exclusionPatterns) {
                            continue
                        }

                        let childArchivePath: String
                        if settings.preserveDirectoryStructure {
                            childArchivePath = archiveDirPath + "/" + childName
                        } else {
                            childArchivePath = childName
                        }

                        if FileUtils.isDirectory(at: child) {
                            try await collectSubdirectory(
                                url: child,
                                archiveBasePath: childArchivePath,
                                settings: settings,
                                fileEntries: &fileEntries
                            )
                        } else {
                            let size = FileUtils.fileSize(at: child)
                            let mtime = time_t(FileUtils.fileModificationDate(at: child)?.timeIntervalSince1970 ?? 0)
                            fileEntries.append((
                                sourcePath: child.path,
                                archivePath: childArchivePath,
                                size: size,
                                mtime: mtime,
                                isDir: false
                            ))
                        }
                    }
                } else {
                    // Flatten mode: recurse into directory but flatten paths
                    try await collectFilesFlat(
                        directory: url,
                        settings: settings,
                        fileEntries: &fileEntries
                    )
                }
            } else {
                let archivePath: String
                if let parent = commonParent {
                    archivePath = url.path.replacingOccurrences(of: parent.path + "/", with: "")
                } else {
                    archivePath = name
                }

                let size = FileUtils.fileSize(at: url)
                let mtime = time_t(FileUtils.fileModificationDate(at: url)?.timeIntervalSince1970 ?? 0)
                fileEntries.append((
                    sourcePath: url.path,
                    archivePath: archivePath,
                    size: size,
                    mtime: mtime,
                    isDir: false
                ))
            }
        }
    }

    private func collectSubdirectory(
        url: URL,
        archiveBasePath: String,
        settings: CompressionSettings,
        fileEntries: inout [(sourcePath: String, archivePath: String, size: Int64, mtime: time_t, isDir: Bool)]
    ) async throws {
        let name = url.lastPathComponent
        if isExcluded(name: name, patterns: settings.exclusionPatterns) { return }

        fileEntries.append((
            sourcePath: url.path,
            archivePath: archiveBasePath,
            size: 0,
            mtime: time_t(FileUtils.fileModificationDate(at: url)?.timeIntervalSince1970 ?? 0),
            isDir: true
        ))

        let children = FileUtils.enumerateDirectory(at: url)
        for child in children {
            let childName = child.lastPathComponent
            if isExcluded(name: childName, patterns: settings.exclusionPatterns) { continue }

            let childArchivePath = archiveBasePath + "/" + childName
            if FileUtils.isDirectory(at: child) {
                try await collectSubdirectory(
                    url: child,
                    archiveBasePath: childArchivePath,
                    settings: settings,
                    fileEntries: &fileEntries
                )
            } else {
                let size = FileUtils.fileSize(at: child)
                let mtime = time_t(FileUtils.fileModificationDate(at: child)?.timeIntervalSince1970 ?? 0)
                fileEntries.append((
                    sourcePath: child.path,
                    archivePath: childArchivePath,
                    size: size,
                    mtime: mtime,
                    isDir: false
                ))
            }
        }
    }

    private func collectFilesFlat(
        directory: URL,
        settings: CompressionSettings,
        fileEntries: inout [(sourcePath: String, archivePath: String, size: Int64, mtime: time_t, isDir: Bool)]
    ) async throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if isExcluded(name: name, patterns: settings.exclusionPatterns) { continue }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory == true

            if isDir { continue } // Skip directories in flat mode

            let size = Int64(values?.fileSize ?? 0)
            let mtime = time_t(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            fileEntries.append((
                sourcePath: fileURL.path,
                archivePath: name,
                size: size,
                mtime: mtime,
                isDir: false
            ))
        }
    }

    private func isExcluded(name: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if name == pattern { return true }
            // Simple wildcard: * at end
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                if name.hasPrefix(prefix) { return true }
            }
            // Simple wildcard: * at beginning
            if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                if name.hasSuffix(suffix) { return true }
            }
        }
        return false
    }

    private func configureFormat(_ archive: OpaquePointer, format: ArchiveFormat) -> Int32 {
        switch format {
        case .zip:
            return archive_write_set_format_zip(archive)
        case .sevenZip:
            return archive_write_set_format_7zip(archive)
        case .tarGz:
            return archive_write_set_format_ustar(archive)
        }
    }

    private func configureFilter(_ archive: OpaquePointer, format: ArchiveFormat) -> Int32 {
        switch format {
        case .zip:
            return ARCHIVE_OK // ZIP handles compression internally via format
        case .sevenZip:
            return ARCHIVE_OK // 7z handles compression internally via format
        case .tarGz:
            return archive_write_add_filter_gzip(archive)
        }
    }

    private func writeDirectoryEntry(archive: OpaquePointer, archivePath: String, mtime: time_t) throws {
        guard let entry = archive_entry_new() else {
            throw ArchiveWriterError.entryCreationFailed
        }
        defer { archive_entry_free(entry) }

        // Ensure path ends with / for directories
        let path = archivePath.hasSuffix("/") ? archivePath : archivePath + "/"
        archive_entry_set_pathname(entry, path)
        archive_entry_set_filetype(entry, 0o040000)
        archive_entry_set_perm(entry, 0o755)
        archive_entry_set_mtime(entry, mtime, 0)
        archive_entry_set_size(entry, 0)

        let result = archive_write_header(archive, entry)
        guard result == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.headerWriteFailed(err)
        }
    }

    private func writeFileEntry(
        archive: OpaquePointer,
        sourceURL: URL,
        archivePath: String,
        size: Int64,
        mtime: time_t
    ) throws {
        guard let entry = archive_entry_new() else {
            throw ArchiveWriterError.entryCreationFailed
        }
        defer { archive_entry_free(entry) }

        archive_entry_set_pathname(entry, archivePath)
        archive_entry_set_filetype(entry, 0o100000)
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_mtime(entry, mtime, 0)
        archive_entry_set_size(entry, size)

        let headerResult = archive_write_header(archive, entry)
        guard headerResult == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.headerWriteFailed(err)
        }

        // Write data in chunks
        guard let fileHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
            // Fallback: read entire file into memory
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    guard let baseAddress = buffer.baseAddress else { return }
                    try writeDataWithRetry(archive: archive, bytes: baseAddress, length: size)
                }
            } catch let error as ArchiveWriterError {
                throw error
            } catch {
                throw ArchiveWriterError.fileReadFailed(sourceURL, error)
            }
            return
        }
        defer { try? fileHandle.close() }

        let chunkSize = 64 * 1024 // 64KB chunks
        var remaining = size

        while remaining > 0 {
            let toRead = min(Int64(chunkSize), remaining)
            guard let data = try fileHandle.read(upToCount: Int(toRead)) else {
                throw ArchiveWriterError.fileReadFailed(sourceURL, NSError(domain: "FileHandle", code: -1))
            }
            if data.isEmpty { break }

            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let baseAddress = buffer.baseAddress else { return }
                try writeDataWithRetry(archive: archive, bytes: baseAddress, length: Int64(data.count))
            }

            remaining -= Int64(data.count)
        }
    }

    private func writeDataWithRetry(archive: OpaquePointer, bytes: UnsafeRawPointer, length: Int64) throws {
        var offset: Int = 0
        let total = Int(length)

        while offset < total {
            let written = archive_write_data(archive, bytes.advanced(by: offset), total - offset)

            if written < 0 {
                // Partial write / retry
                if written == ARCHIVE_RETRY {
                    continue
                }
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.dataWriteFailed(err)
            }

            offset += written
        }
    }

    // MARK: - Extract-then-rebuild helpers

    private func detectFormat(from archiveURL: URL) -> ArchiveFormat {
        let ext = archiveURL.pathExtension.lowercased()
        let fullName = archiveURL.lastPathComponent.lowercased()

        if fullName.hasSuffix(".tar.gz") || fullName.hasSuffix(".tgz") {
            return .tarGz
        }
        switch ext {
        case "7z": return .sevenZip
        case "zip": return .zip
        default: return .zip
        }
    }

    private func extractEntries(
        archiveURL: URL,
        to destinationURL: URL,
        excludeNames: Set<String>
    ) async throws {
        guard let archive = archive_read_new() else {
            throw ArchiveWriterError.archiveCreationFailed
        }
        defer { archive_read_free(archive) }

        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)

        let result = archiveURL.path.withCString { path in
            archive_read_open_filename(archive, path, 10240)
        }
        guard result == ARCHIVE_OK else {
            let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
            throw ArchiveWriterError.openFailed(err)
        }

        while true {
            var entryPtr: OpaquePointer?
            let r = archive_read_next_header(archive, &entryPtr)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry = entryPtr else {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }

            let pathname = archive_entry_pathname(entry).map { String(cString: $0) } ?? ""
            let name = (pathname as NSString).lastPathComponent

            // Strip trailing slash for directory name comparison
            let cleanName = name.hasSuffix("/") ? String(name.dropLast()) : name

            if excludeNames.contains(cleanName) || excludeNames.contains(name) {
                archive_read_data_skip(archive)
                continue
            }

            // Set the extraction path
            let destPath = destinationURL.appendingPathComponent(pathname).path

            // Create parent directories if needed
            let destDir = (destPath as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: destDir) {
                try FileManager.default.createDirectory(
                    atPath: destDir,
                    withIntermediateDirectories: true
                )
            }

            archive_entry_set_pathname(entry, destPath)

            let extractResult = archive_read_extract(archive, entry,
                ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_ACL | ARCHIVE_EXTRACT_UNLINK)
            if extractResult != ARCHIVE_OK {
                let err = archive_error_string(archive).map { String(cString: $0) } ?? "unknown"
                throw ArchiveWriterError.extractionFailed(err)
            }
        }
    }
}
