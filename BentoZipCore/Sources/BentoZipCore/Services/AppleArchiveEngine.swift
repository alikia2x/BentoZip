import AppleArchive
import Compression
import Foundation
import System

/// Native macOS AppleArchive engine providing zero-dependency read/write support for `.aar` (and read support for `.yaa`).
struct AppleArchiveEngine: Sendable {
    private static let archiveKeySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")!
    private static let dataKey = ArchiveHeader.FieldKey("DAT")
    private static let mtimeKey = ArchiveHeader.FieldKey("MTM")

    func listArchive(
        in archiveURL: URL,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        let packedSize = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber)?.int64Value

        let flatEntries = try await Task.detached(priority: .userInitiated) {
            try Self.readFlatEntries(at: archiveURL, onProgress: onProgress)
        }.value

        try Task.checkCancellation()
        let tree = ArchiveTreeBuilder.build(from: flatEntries)
        return ArchiveListResult(entries: tree, archivePackedSize: packedSize)
    }

    func create(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        try await Task.detached(priority: .userInitiated) {
            try Self.writeArchive(
                from: sourceURLs,
                to: archiveURL,
                settings: settings,
                onProgress: onProgress
            )
        }.value

        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw Bento7zError.fileNotFound(archiveURL.path)
        }

        let targetPaths = entries.map { Set(Bento7zPathSafety.collectArchivePaths(from: $0).map { Self.normalizePath($0) }) }
        try await Task.detached(priority: .userInitiated) {
            try Self.extractArchive(
                at: archiveURL,
                targetPaths: targetPaths,
                to: destinationURL,
                onProgress: onProgress
            )
        }.value

        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    func extractEntry(
        from archiveURL: URL,
        entryPath: String,
        to destinationURL: URL
    ) async throws {
        let safeRelPath = try Bento7zPathSafety.sanitizedRelativePath(entryPath)
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_aa_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        try await Task.detached(priority: .userInitiated) {
            try Self.extractArchive(
                at: archiveURL,
                targetPaths: Set([safeRelPath]),
                to: tempDir,
                onProgress: { _ in }
            )
        }.value

        let directExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safeRelPath, baseDirectory: tempDir)
        let flatName = (safeRelPath as NSString).lastPathComponent
        let flatExtracted = try Bento7zPathSafety.verifiedDescendantURL(relativePath: flatName, baseDirectory: tempDir)

        let extractedFile: URL
        if fm.fileExists(atPath: directExtracted.path) {
            extractedFile = directExtracted
        } else if fm.fileExists(atPath: flatExtracted.path) {
            extractedFile = flatExtracted
        } else {
            throw Bento7zError.fileNotFound(entryPath)
        }

        let parent = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: extractedFile, to: destinationURL)
    }

    // MARK: - Reading / Listing

    private static func readFlatEntries(
        at archiveURL: URL,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) throws -> [ArchiveTreeBuilder.FlatEntry] {
        var entries: [ArchiveTreeBuilder.FlatEntry] = []
        var totalSizeSoFar: Int64 = 0

        try withDecodeStream(at: archiveURL) { decodeStream in
            while let header = try decodeStream.readHeader() {
                try Task.checkCancellation()
                guard let rawPath = header.entryPath?.string else { continue }
                let normPath = normalizePath(rawPath)
                guard !normPath.isEmpty else { continue }

                let isDir = header.entryType == .directory
                var fileSize: Int64 = 0
                if !isDir, let field = header.field(forKey: dataKey), case .blob(_, let sz, _) = field {
                    fileSize = Int64(min(sz, UInt64(Int64.max)))
                }
                var modDate: Date? = nil
                if let field = header.field(forKey: mtimeKey), case .timespec(_, let ts) = field, ts.tv_sec > 0 {
                    modDate = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec))
                }

                totalSizeSoFar += fileSize
                let name = (normPath as NSString).lastPathComponent
                entries.append(ArchiveTreeBuilder.FlatEntry(
                    path: normPath,
                    name: name.isEmpty ? normPath : name,
                    isDirectory: isDir,
                    size: max(0, fileSize),
                    packedSize: nil,
                    modificationDate: modDate,
                    isEncrypted: false
                ))

                if entries.count & 0x3F == 0 {
                    onProgress?(ArchiveProgress(
                        fractionCompleted: 0.0,
                        currentFile: name,
                        processedBytes: Int64(entries.count),
                        totalBytes: nil,
                        isFileEvent: true,
                        stage: .readingEntries
                    ))
                }
            }
        }
        return entries
    }

    // MARK: - Extracting

    private static func extractArchive(
        at archiveURL: URL,
        targetPaths: Set<String>?,
        to destinationURL: URL,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) throws {
        // First pass: validate paths for traversal safety and compute total uncompressed bytes.
        var totalBytes: Int64 = 0
        var fileSizesByPath: [String: Int64] = [:]
        try withDecodeStream(at: archiveURL) { decodeStream in
            while let header = try decodeStream.readHeader() {
                try Task.checkCancellation()
                guard let rawPath = header.entryPath?.string else { continue }
                let norm = normalizePath(rawPath)
                guard !norm.isEmpty else { continue }
                _ = try Bento7zPathSafety.verifiedDescendantURL(relativePath: norm, baseDirectory: destinationURL)
                if header.entryType != .directory,
                   let field = header.field(forKey: dataKey),
                   case .blob(_, let sz, _) = field {
                    let size = Int64(min(sz, UInt64(Int64.max)))
                    fileSizesByPath[norm] = size
                    if targetPaths == nil || matchesTarget(norm, targets: targetPaths!) {
                        totalBytes += size
                    }
                }
            }
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var processedBytes: Int64 = 0
        let destPath = FilePath(destinationURL.path)

        try withDecodeStream(at: archiveURL) { decodeStream in
            try ArchiveStream.withExtractStream(extractingTo: destPath) { extractStream in
                _ = try ArchiveStream.process(
                    readingFrom: decodeStream,
                    writingTo: extractStream,
                    selectUsing: { message, path, _ in
                        if Task.isCancelled {
                            return .cancel
                        }
                        let norm = normalizePath(path.string)
                        if let targets = targetPaths, !norm.isEmpty, !matchesTarget(norm, targets: targets) {
                            return .skip
                        }

                        if message == .extractBegin {
                            let fileName = (norm as NSString).lastPathComponent
                            let fraction = totalBytes > 0
                                ? min(1.0, Double(processedBytes) / Double(totalBytes))
                                : 0.0
                            onProgress(ArchiveProgress(
                                fractionCompleted: fraction,
                                currentFile: fileName.isEmpty ? nil : fileName,
                                processedBytes: processedBytes,
                                totalBytes: totalBytes > 0 ? totalBytes : nil,
                                isFileEvent: false
                            ))
                        } else if message == .extractEnd {
                            let sz = fileSizesByPath[norm] ?? 0
                            processedBytes += sz
                            let fileName = (norm as NSString).lastPathComponent
                            let fraction = totalBytes > 0
                                ? min(1.0, Double(processedBytes) / Double(totalBytes))
                                : 0.0
                            onProgress(ArchiveProgress(
                                fractionCompleted: fraction,
                                currentFile: fileName.isEmpty ? nil : fileName,
                                processedBytes: processedBytes,
                                totalBytes: totalBytes > 0 ? totalBytes : nil,
                                isFileEvent: true
                            ))
                        }
                        return .ok
                    }
                )
            }
        }
    }

    // MARK: - Creating

    private static func writeArchive(
        from sourceURLs: [URL],
        to archiveURL: URL,
        settings: CompressionSettings,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_aa_stage_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var totalBytes: Int64 = 0
        for url in sourceURLs {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: url.path) else {
                throw Bento7zError.fileNotFound(url.path)
            }
            let copiedBytes = try stageInput(
                url,
                into: stagingDir,
                preserveStructure: settings.preserveDirectoryStructure,
                exclusions: settings.exclusionPatterns
            )
            totalBytes += copiedBytes
        }

        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }

        let compression = mapCompression(settings.compressionLevel)
        var processedBytes: Int64 = 0

        let writeBlock: (ArchiveStream) throws -> Void = { encodeStream in
            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(stagingDir.path),
                path: nil,
                keySet: archiveKeySet,
                selectUsing: { message, path, data in
                    if Task.isCancelled {
                        return .cancel
                    }
                    let norm = normalizePath(path.string)
                    if (message == .encodeScanning || message == .encodeWriting),
                       !norm.isEmpty {
                        if message == .encodeWriting, case .header(let header)? = data {
                            if let field = header.field(forKey: dataKey), case .blob(_, let sz, _) = field {
                                processedBytes += Int64(min(sz, UInt64(Int64.max)))
                            }
                            let fraction = totalBytes > 0
                                ? min(0.99, Double(processedBytes) / Double(totalBytes))
                                : 0.0
                            let name = (norm as NSString).lastPathComponent
                            onProgress(ArchiveProgress(
                                fractionCompleted: fraction,
                                currentFile: name.isEmpty ? nil : name,
                                processedBytes: processedBytes,
                                totalBytes: totalBytes > 0 ? totalBytes : nil,
                                isFileEvent: true
                            ))
                        }
                    }
                    return .ok
                }
            )
        }

        try ArchiveByteStream.withFileStream(
            path: FilePath(archiveURL.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        ) { fileStream in
            if compression == .none {
                try ArchiveStream.withEncodeStream(writingTo: fileStream) { encodeStream in
                    try writeBlock(encodeStream)
                }
            } else {
                try ArchiveByteStream.withCompressionStream(using: compression, writingTo: fileStream) { compStream in
                    try ArchiveStream.withEncodeStream(writingTo: compStream) { encodeStream in
                        try writeBlock(encodeStream)
                    }
                }
            }
        }
    }

    // MARK: - Stream Helpers

    private static func withDecodeStream<T>(
        at archiveURL: URL,
        _ body: (ArchiveStream) throws -> T
    ) throws -> T {
        let isRaw = isRawUncompressedAA(at: archiveURL)
        return try ArchiveByteStream.withFileStream(
            path: FilePath(archiveURL.path),
            mode: .readOnly,
            options: [],
            permissions: []
        ) { fileStream in
            if isRaw {
                return try ArchiveStream.withDecodeStream(readingFrom: fileStream) { decodeStream in
                    try body(decodeStream)
                }
            } else {
                return try ArchiveByteStream.withDecompressionStream(readingFrom: fileStream) { decompStream in
                    try ArchiveStream.withDecodeStream(readingFrom: decompStream) { decodeStream in
                        try body(decodeStream)
                    }
                }
            }
        }
    }

    private static func isRawUncompressedAA(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        return [UInt8](header) == [0x59, 0x41, 0x41, 0x31] // "YAA1"
    }

    private static func mapCompression(_ level: CompressionLevel) -> ArchiveCompression {
        switch level {
        case .none: return .none
        case .fast: return .lz4
        case .normal: return .lzfse
        case .best: return .lzma
        }
    }

    private static func stageInput(
        _ url: URL,
        into stagingDir: URL,
        preserveStructure: Bool,
        exclusions: [String]
    ) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if isExcluded(name: url.lastPathComponent, relativePath: url.lastPathComponent, patterns: exclusions) {
            return 0
        }

        if !isDir.boolValue {
            let dest = stagingDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
            let sz = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return sz
        }

        var copiedBytes: Int64 = 0
        let rootName = url.lastPathComponent
        let baseDest = preserveStructure ? stagingDir.appendingPathComponent(rootName, isDirectory: true) : stagingDir
        if preserveStructure {
            try fm.createDirectory(at: baseDest, withIntermediateDirectories: true)
        }

        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) {
            for case let childURL as URL in enumerator {
                try Task.checkCancellation()
                let relFromSource = relativeSubpath(of: childURL, under: url)
                guard !relFromSource.isEmpty else { continue }
                let archiveRel = preserveStructure ? "\(rootName)/\(relFromSource)" : relFromSource

                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let childIsDir = values?.isDirectory ?? false

                if isExcluded(name: childURL.lastPathComponent, relativePath: archiveRel, patterns: exclusions) {
                    if childIsDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let targetURL = preserveStructure
                    ? baseDest.appendingPathComponent(relFromSource)
                    : stagingDir.appendingPathComponent(childURL.lastPathComponent)

                if childIsDir {
                    if preserveStructure {
                        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    }
                } else {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: targetURL)
                    try fm.copyItem(at: childURL, to: targetURL)
                    copiedBytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return copiedBytes
    }

    private static func relativeSubpath(of childURL: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let childPath = childURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else { return "" }
        return String(childPath.dropFirst(prefix.count))
    }

    private static func isExcluded(name: String, relativePath: String, patterns: [String]) -> Bool {
        for raw in patterns where !raw.isEmpty {
            let pat = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !pat.isEmpty else { continue }
            let target = pat.contains("/") ? relativePath : name
            if fnmatch(pat, target, 0) == 0 {
                return true
            }
        }
        return false
    }

    private static func normalizePath(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        return s == "." ? "" : s
    }

    private static func matchesTarget(_ normPath: String, targets: Set<String>) -> Bool {
        if targets.contains(normPath) { return true }
        for target in targets {
            if normPath.hasPrefix(target + "/") { return true }
        }
        return false
    }
}
