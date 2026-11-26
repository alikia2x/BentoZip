import Foundation

/// Detailed progress update emitted by an archive engine during compress/extract/browse operations.
public struct ArchiveProgress: Sendable, Equatable {
    public enum Stage: UInt8, Sendable, Equatable {
        case normal = 0
        case unpackingOuter = 1
        case readingEntries = 2
        case compressingOuter = 3
        case packingTar = 4
        case extractingInner = 5
    }

    public let fractionCompleted: Double
    public let currentFile: String?
    public let processedBytes: Int64?
    public let totalBytes: Int64?
    public let isFileEvent: Bool
    public let fileCountDelta: Int
    public let stage: Stage

    public init(
        fractionCompleted: Double,
        currentFile: String? = nil,
        processedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        isFileEvent: Bool = false,
        fileCountDelta: Int? = nil,
        stage: Stage = .normal
    ) {
        self.fractionCompleted = fractionCompleted
        self.currentFile = currentFile
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.isFileEvent = isFileEvent
        self.fileCountDelta = fileCountDelta ?? (isFileEvent ? 1 : 0)
        self.stage = stage
    }
}

/// Result of listing an archive's entries along with optional archive-level packed size.
public struct ArchiveListResult: Sendable, Equatable {
    public let entries: [FileEntry]
    public let archivePackedSize: Int64?
    public let unwrappedRootPath: String?
    public let archiveComment: String?

    public init(
        entries: [FileEntry],
        archivePackedSize: Int64? = nil,
        unwrappedRootPath: String? = nil,
        archiveComment: String? = nil
    ) {
        self.entries = entries
        self.archivePackedSize = archivePackedSize
        self.unwrappedRootPath = unwrappedRootPath
        self.archiveComment = archiveComment
    }
}

/// Result of verifying archive integrity via engine test operation.
public struct ArchiveTestResult: Sendable, Equatable {
    public let itemsCount: Int

    public init(itemsCount: Int) {
        self.itemsCount = itemsCount
    }
}

/// Protocol implemented by archive backend engines.
public protocol ArchiveEngine: Sendable {
    func listEntries(in archiveURL: URL, password: String?) async throws -> [FileEntry]

    func listArchive(in archiveURL: URL, password: String?) async throws -> ArchiveListResult

    func listArchive(
        in archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult

    func listArchive(
        in archiveURL: URL,
        password: String?,
        encoding: String?,
        unwrapSingleTopDirectory: Bool,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String?,
        encoding: String?,
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

    func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        targetPrefix: String?,
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws

    func renameEntry(
        in archiveURL: URL,
        from oldPath: String,
        to newPath: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws

    func createFolder(
        in archiveURL: URL,
        path: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws

    func testArchive(
        at archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveTestResult

    func moveEntries(
        in archiveURL: URL,
        entries: [FileEntry],
        toTargetDir targetDir: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws

    func updatePassword(
        in archiveURL: URL,
        oldPassword: String?,
        newPassword: String?,
        encryptionMethod: String?,
        encryptHeaders: Bool,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
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

    func listArchive(
        in archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        try await listArchive(in: archiveURL, password: password)
    }

    func listArchive(
        in archiveURL: URL,
        password: String?,
        encoding: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        try await listArchive(
            in: archiveURL,
            password: password,
            encoding: encoding,
            unwrapSingleTopDirectory: true,
            onProgress: onProgress
        )
    }

    func listArchive(
        in archiveURL: URL,
        password: String?,
        encoding: String?,
        unwrapSingleTopDirectory: Bool,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveListResult {
        try await listArchive(in: archiveURL, password: password, onProgress: onProgress)
    }

    func listArchive(in archiveURL: URL) async throws -> ArchiveListResult {
        try await listArchive(in: archiveURL, password: nil)
    }

    func extract(
        archiveURL: URL,
        entries: [FileEntry]?,
        to destinationURL: URL,
        password: String?,
        encoding: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try await extract(
            archiveURL: archiveURL,
            entries: entries,
            to: destinationURL,
            password: password,
            onProgress: onProgress
        )
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
        targetPrefix: String?,
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        try await addEntries(
            to: archiveURL,
            from: sourceURLs,
            password: password,
            onProgress: onProgress
        )
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

    func renameEntry(
        in archiveURL: URL,
        from oldPath: String,
        to newPath: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        throw Bento7zError.operationFailed(
            String(localized: "Renaming entries is not supported by this engine.", bundle: .module),
            "UNSUPPORTED_OPERATION"
        )
    }

    func createFolder(
        in archiveURL: URL,
        path: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        let safePath = try Bento7zPathSafety.validatedRelativePath(path)
        let components = safePath.split(separator: "/").map(String.init)
        guard let folderName = components.last, !folderName.isEmpty else {
            throw Bento7zError.operationFailed(
                String(localized: "Invalid folder path: \(path)", bundle: .module),
                "INVALID_PATH"
            )
        }
        let parentPrefix = components.count > 1 ? components.dropLast().joined(separator: "/") : nil

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_mkdir_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        let folderURL = tempDir.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        try await addEntries(
            to: archiveURL,
            from: [folderURL],
            targetPrefix: parentPrefix,
            password: password,
            onProgress: onProgress ?? { _ in }
        )
    }

    func testArchive(
        at archiveURL: URL,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws -> ArchiveTestResult {
        throw Bento7zError.operationFailed(
            String(localized: "Testing archives is not supported by this engine.", bundle: .module),
            "UNSUPPORTED_OPERATION"
        )
    }

    func moveEntries(
        in archiveURL: URL,
        entries: [FileEntry],
        toTargetDir targetDir: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        throw Bento7zError.operationFailed(
            String(localized: "Moving entries is not supported by this engine.", bundle: .module),
            "UNSUPPORTED_OPERATION"
        )
    }

    func updatePassword(
        in archiveURL: URL,
        oldPassword: String?,
        newPassword: String?,
        encryptionMethod: String?,
        encryptHeaders: Bool,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        throw Bento7zError.operationFailed(
            String(localized: "Updating archive password is not supported by this engine.", bundle: .module),
            "UNSUPPORTED_OPERATION"
        )
    }
}
