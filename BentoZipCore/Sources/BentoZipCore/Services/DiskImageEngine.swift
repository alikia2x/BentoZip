import Darwin
import Foundation
import os

/// Creates compressed macOS `.dmg` disk images asynchronously via `/usr/bin/hdiutil`.
public struct DiskImageEngine: Sendable {
    public static let hdiutilPath = "/usr/bin/hdiutil"

    public init() {}

    public func create(
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

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.hdiutilPath) else {
            throw Bento7zError.binaryNotFound(Self.hdiutilPath)
        }

        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("BentoZip_dmg_stage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        onProgress(ArchiveProgress(fractionCompleted: 0.05, currentFile: archiveURL.lastPathComponent))

        let totalBytes = try await Task.detached(priority: .userInitiated) {
            try Self.stageSources(sourceURLs, into: stagingDir, settings: settings)
        }.value

        try Task.checkCancellation()

        let parentDir = archiveURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL)
        }

        let rawStem = archiveURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let volumeName = rawStem.isEmpty ? "Archive" : rawStem

        onProgress(ArchiveProgress(
            fractionCompleted: 0.25,
            currentFile: archiveURL.lastPathComponent,
            processedBytes: 0,
            totalBytes: totalBytes > 0 ? totalBytes : nil
        ))

        let arguments = [
            "create",
            "-volname", volumeName,
            "-srcfolder", stagingDir.path,
            "-fs", "HFS+",
            "-ov",
            "-format", "UDZO",
            archiveURL.path
        ]

        do {
            try await Self.runSubprocess(executablePath: Self.hdiutilPath, arguments: arguments)
            try Task.checkCancellation()
            onProgress(ArchiveProgress(
                fractionCompleted: 1.0,
                currentFile: archiveURL.lastPathComponent,
                processedBytes: totalBytes > 0 ? totalBytes : nil,
                totalBytes: totalBytes > 0 ? totalBytes : nil
            ))
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    // MARK: - Staging

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func stageSources(
        _ sourceURLs: [URL],
        into stagingDir: URL,
        settings: CompressionSettings
    ) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var totalBytes: Int64 = 0
        for url in sourceURLs {
            try Task.checkCancellation()
            guard Bento7zPathSafety.itemExists(at: url) else {
                throw Bento7zError.fileNotFound(url.path)
            }
            totalBytes += try stageSingleSource(
                url,
                into: stagingDir,
                preserveStructure: settings.preserveDirectoryStructure,
                followSymlinks: settings.followSymlinks,
                exclusions: settings.exclusionPatterns
            )
        }
        return totalBytes
    }

    private static func stageSingleSource(
        _ url: URL,
        into stagingDir: URL,
        preserveStructure: Bool,
        followSymlinks: Bool,
        exclusions: [String]
    ) throws -> Int64 {
        let fm = FileManager.default
        let lstatStatus = Bento7zPathSafety.itemStatus(at: url)
        guard lstatStatus.exists else { return 0 }

        let rootName = url.lastPathComponent
        if isExcluded(name: rootName, relativePath: rootName, patterns: exclusions) {
            return 0
        }

        let isRootSymlink = isSymbolicLink(at: url)
        let effectiveURL = (isRootSymlink && followSymlinks) ? url.resolvingSymlinksInPath() : url
        let effectiveStatus = followSymlinks
            ? resolvedStatStatus(at: effectiveURL)
            : lstatFileStatus(at: url)

        guard let effectiveStatus else {
            // Broken symlink when following symlinks: preserve symlink entry safely
            let target = PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(rootName))
            try copyEntry(from: url, resolvedURL: url, to: target, followSymlinks: false)
            return 0
        }

        if !effectiveStatus.isDirectory {
            let target = PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(rootName))
            try copyEntry(from: url, resolvedURL: effectiveURL, to: target, followSymlinks: followSymlinks)
            return max(0, effectiveStatus.size)
        }

        let baseDest = preserveStructure
            ? PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(rootName, isDirectory: true))
            : stagingDir
        if preserveStructure {
            try fm.createDirectory(at: baseDest, withIntermediateDirectories: true)
        }

        var activeDirectories: Set<FileIdentity> = [effectiveStatus.identity]
        return try stageDirectoryContents(
            sourceDir: effectiveURL,
            destDir: baseDest,
            stagingRoot: stagingDir,
            archiveRelativePrefix: preserveStructure ? rootName : "",
            preserveStructure: preserveStructure,
            followSymlinks: followSymlinks,
            exclusions: exclusions,
            activeDirectories: &activeDirectories
        )
    }

    private static func stageDirectoryContents(
        sourceDir: URL,
        destDir: URL,
        stagingRoot: URL,
        archiveRelativePrefix: String,
        preserveStructure: Bool,
        followSymlinks: Bool,
        exclusions: [String],
        activeDirectories: inout Set<FileIdentity>
    ) throws -> Int64 {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
            options: []
        )

        var copiedBytes: Int64 = 0
        for childURL in children {
            try Task.checkCancellation()
            let childName = childURL.lastPathComponent
            let archiveRel = archiveRelativePrefix.isEmpty ? childName : "\(archiveRelativePrefix)/\(childName)"

            if isExcluded(name: childName, relativePath: archiveRel, patterns: exclusions) {
                continue
            }

            let isSymlink = isSymbolicLink(at: childURL)
            if isSymlink && !followSymlinks {
                let targetURL = preserveStructure
                    ? destDir.appendingPathComponent(childName)
                    : PathUtils.uniqueFileURL(for: stagingRoot.appendingPathComponent(childName))
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyEntry(from: childURL, resolvedURL: childURL, to: targetURL, followSymlinks: false)
                continue
            }

            let targetStat = followSymlinks
                ? resolvedStatStatus(at: childURL)
                : lstatFileStatus(at: childURL)

            guard let targetStat else {
                // Dangling symlink when followSymlinks is enabled: preserve link without crashing
                let targetURL = preserveStructure
                    ? destDir.appendingPathComponent(childName)
                    : PathUtils.uniqueFileURL(for: stagingRoot.appendingPathComponent(childName))
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyEntry(from: childURL, resolvedURL: childURL, to: targetURL, followSymlinks: false)
                continue
            }

            if targetStat.isDirectory {
                guard activeDirectories.insert(targetStat.identity).inserted else {
                    continue
                }
                defer { activeDirectories.remove(targetStat.identity) }

                let nextSource = (isSymlink && followSymlinks) ? childURL.resolvingSymlinksInPath() : childURL
                let nextDest = preserveStructure
                    ? destDir.appendingPathComponent(childName, isDirectory: true)
                    : stagingRoot
                if preserveStructure {
                    try fm.createDirectory(at: nextDest, withIntermediateDirectories: true)
                }
                copiedBytes += try stageDirectoryContents(
                    sourceDir: nextSource,
                    destDir: nextDest,
                    stagingRoot: stagingRoot,
                    archiveRelativePrefix: archiveRel,
                    preserveStructure: preserveStructure,
                    followSymlinks: followSymlinks,
                    exclusions: exclusions,
                    activeDirectories: &activeDirectories
                )
            } else {
                let targetURL = preserveStructure
                    ? destDir.appendingPathComponent(childName)
                    : PathUtils.uniqueFileURL(for: stagingRoot.appendingPathComponent(childName))
                try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let resolvedChild = (isSymlink && followSymlinks) ? childURL.resolvingSymlinksInPath() : childURL
                try copyEntry(from: childURL, resolvedURL: resolvedChild, to: targetURL, followSymlinks: followSymlinks)
                copiedBytes += max(0, targetStat.size)
            }
        }
        return copiedBytes
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func lstatFileStatus(at url: URL) -> (isDirectory: Bool, size: Int64, identity: FileIdentity)? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        return (isDir, Int64(st.st_size), FileIdentity(device: st.st_dev, inode: st.st_ino))
    }

    private static func resolvedStatStatus(at url: URL) -> (isDirectory: Bool, size: Int64, identity: FileIdentity)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        return (isDir, Int64(st.st_size), FileIdentity(device: st.st_dev, inode: st.st_ino))
    }

    private static func copyEntry(from originalURL: URL, resolvedURL: URL, to targetURL: URL, followSymlinks: Bool) throws {
        let fm = FileManager.default
        if Bento7zPathSafety.itemExists(at: targetURL) {
            try fm.removeItem(at: targetURL)
        }
        if followSymlinks && originalURL != resolvedURL && Bento7zPathSafety.itemExists(at: resolvedURL) {
            try fm.copyItem(at: resolvedURL, to: targetURL)
        } else {
            try fm.copyItem(at: originalURL, to: targetURL)
        }
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

    // MARK: - Async Non-Blocking Subprocess Runner

    static func runSubprocess(executablePath: String, arguments: [String]) async throws {
        let controller = ProcessController()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try await Self.executeProcess(
                    executablePath: executablePath,
                    arguments: arguments,
                    controller: controller
                )
            }.value
        } onCancel: {
            controller.cancel()
        }
    }

    private static func executeProcess(
        executablePath: String,
        arguments: [String],
        controller: ProcessController
    ) async throws {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct ExitState: Sendable {
            var status: Int32?
            var stdoutEOF = false
            var stderrEOF = false
            var continuation: CheckedContinuation<Int32, Never>?

            mutating func takeReadyContinuationIfComplete() -> (CheckedContinuation<Int32, Never>, Int32)? {
                guard let status, stdoutEOF, stderrEOF, let cont = continuation else {
                    return nil
                }
                continuation = nil
                return (cont, status)
            }
        }
        let exitLock = OSAllocatedUnfairLock(initialState: ExitState())
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            let pending = exitLock.withLock { state -> (CheckedContinuation<Int32, Never>, Int32)? in
                state.status = status
                return state.takeReadyContinuationIfComplete()
            }
            if let (cont, exitStatus) = pending {
                cont.resume(returning: exitStatus)
            }
        }

        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                let pending = exitLock.withLock { state -> (CheckedContinuation<Int32, Never>, Int32)? in
                    state.stderrEOF = true
                    return state.takeReadyContinuationIfComplete()
                }
                if let (cont, exitStatus) = pending {
                    cont.resume(returning: exitStatus)
                }
            } else {
                stderrBuffer.withLock {
                    let remaining = 65_536 - $0.count
                    if remaining > 0 {
                        $0.append(chunk.prefix(remaining))
                    }
                }
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                let pending = exitLock.withLock { state -> (CheckedContinuation<Int32, Never>, Int32)? in
                    state.stdoutEOF = true
                    return state.takeReadyContinuationIfComplete()
                }
                if let (cont, exitStatus) = pending {
                    cont.resume(returning: exitStatus)
                }
            }
        }

        var processLaunched = false
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let (needCloseStdout, needCloseStderr) = exitLock.withLock { state in
                (!state.stdoutEOF, !state.stderrEOF)
            }
            if needCloseStdout {
                try? stdoutPipe.fileHandleForReading.close()
            }
            if needCloseStderr {
                try? stderrPipe.fileHandleForReading.close()
            }
            if !processLaunched {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
            }
            controller.detach()
        }

        guard controller.attach(process) else { throw CancellationError() }
        try process.run()
        processLaunched = true

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            let readyStatus = exitLock.withLock { state -> Int32? in
                if let status = state.status, state.stdoutEOF, state.stderrEOF {
                    return status
                }
                state.continuation = continuation
                return nil
            }
            if let readyStatus {
                continuation.resume(returning: readyStatus)
            }
        }

        if Task.isCancelled || controller.isCancelled {
            throw CancellationError()
        }

        guard exitStatus == 0 else {
            let stderrText = stderrBuffer.withLock {
                String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let detail = stderrText.isEmpty
                ? String(localized: "Exit code \(Int64(exitStatus))", bundle: .module)
                : String(localized: "Exit code \(Int64(exitStatus)): \(stderrText)", bundle: .module)
            throw Bento7zError.processError(detail)
        }
    }
}
