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
        let status = Bento7zPathSafety.itemStatus(at: url)
        guard status.exists else { return 0 }

        let rootName = url.lastPathComponent
        if isExcluded(name: rootName, relativePath: rootName, patterns: exclusions) {
            return 0
        }

        let rootValues = try? url.resourceValues(forKeys: Set<URLResourceKey>([.isSymbolicLinkKey]))
        let isRootSymlink = rootValues?.isSymbolicLink ?? false
        let effectiveURL = (isRootSymlink && followSymlinks) ? url.resolvingSymlinksInPath() : url
        let effectiveStatus = Bento7zPathSafety.itemStatus(at: effectiveURL)

        if !effectiveStatus.isDirectory {
            let target = PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(rootName))
            try copyEntry(from: url, resolvedURL: effectiveURL, to: target, followSymlinks: followSymlinks)
            let size = (try? fm.attributesOfItem(atPath: effectiveURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            return size
        }

        var copiedBytes: Int64 = 0
        let baseDest = preserveStructure
            ? PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(rootName, isDirectory: true))
            : stagingDir
        if preserveStructure {
            try fm.createDirectory(at: baseDest, withIntermediateDirectories: true)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let keySet = Set(keys)
        if let enumerator = fm.enumerator(
            at: effectiveURL,
            includingPropertiesForKeys: keys,
            options: []
        ) {
            for case let childURL as URL in enumerator {
                try Task.checkCancellation()
                let relFromSource = relativeSubpath(of: childURL, under: effectiveURL)
                guard !relFromSource.isEmpty else { continue }
                let archiveRel = preserveStructure ? "\(rootName)/\(relFromSource)" : relFromSource

                let values = try? childURL.resourceValues(forKeys: keySet)
                let isSymlink = values?.isSymbolicLink ?? false
                let childIsDir = (values?.isDirectory ?? false) && !isSymlink

                if isExcluded(name: childURL.lastPathComponent, relativePath: archiveRel, patterns: exclusions) {
                    if childIsDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let targetURL = preserveStructure
                    ? baseDest.appendingPathComponent(relFromSource)
                    : PathUtils.uniqueFileURL(for: stagingDir.appendingPathComponent(childURL.lastPathComponent))

                if childIsDir {
                    if preserveStructure {
                        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    }
                } else {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let resolvedChild = (isSymlink && followSymlinks) ? childURL.resolvingSymlinksInPath() : childURL
                    try copyEntry(from: childURL, resolvedURL: resolvedChild, to: targetURL, followSymlinks: followSymlinks)
                    copiedBytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return copiedBytes
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
            var continuation: CheckedContinuation<Int32, Never>?
        }
        let exitLock = OSAllocatedUnfairLock(initialState: ExitState())
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            let pending = exitLock.withLock { state -> CheckedContinuation<Int32, Never>? in
                state.status = status
                defer { state.continuation = nil }
                return state.continuation
            }
            pending?.resume(returning: status)
        }

        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.withLock { if $0.count < 65_536 { $0.append(chunk) } }
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            controller.detach()
        }

        guard controller.attach(process) else { throw CancellationError() }
        try process.run()

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            let alreadyExited = exitLock.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.continuation = continuation
                return nil
            }
            if let status = alreadyExited {
                continuation.resume(returning: status)
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
