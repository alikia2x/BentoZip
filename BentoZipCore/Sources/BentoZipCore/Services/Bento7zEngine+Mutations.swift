import Foundation

extension Bento7zEngine {

    public func removeEntries(
        from archiveURL: URL,
        entries: [FileEntry],
        password: String? = nil
    ) async throws {
        guard !entries.isEmpty else { return }
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed(
                String(localized: "Read-only archive formats cannot be modified.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }

        let fm = FileManager.default
        if prefersBinaryServer && Self.supportsInPlaceEdit(format) {
            do {
                try await deleteInPlaceBinary(from: archiveURL, format: format, entries: entries, password: password)
                cacheManager.invalidate(for: archiveURL)
                return
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error, code == "UNSUPPORTED_INPLACE" {
                    // Fall back to atomic extract-and-rebuild (e.g. solid 7z archives).
                } else {
                    throw error
                }
            }
        }

        let allEntries = try await listEntries(in: archiveURL, password: password)
        let removalPaths = Set(entries.map { Bento7zPathSafety.archiveRelativePath(for: $0) })
        let allPaths = Set(allEntries.map { Bento7zPathSafety.archiveRelativePath(for: $0) })

        if removalPaths.isSuperset(of: allPaths) && !allPaths.isEmpty {
            try fm.removeItem(at: archiveURL)
            return
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_remove_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Validate all target removal paths up front before touching the filesystem.
        var validatedTargets: [(primary: URL, fallback: URL?)] = []
        validatedTargets.reserveCapacity(entries.count)
        for entry in entries {
            let relPath = Bento7zPathSafety.archiveRelativePath(for: entry)
            let directTarget = try Bento7zPathSafety.verifiedDescendantURL(relativePath: relPath, baseDirectory: extractDir)
            let fallbackTarget: URL?
            if !entry.name.isEmpty,
               !entry.name.contains("/"),
               !entry.name.contains("\\"),
               entry.name != ".",
               entry.name != ".." {
                fallbackTarget = try Bento7zPathSafety.verifiedDescendantURL(relativePath: entry.name, baseDirectory: extractDir)
            } else {
                fallbackTarget = nil
            }
            validatedTargets.append((directTarget, fallbackTarget))
        }

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: password,
            onProgress: { _ in }
        )

        for target in validatedTargets {
            if fm.fileExists(atPath: target.primary.path) {
                try fm.removeItem(at: target.primary)
                continue
            }
            if let fallback = target.fallback, fm.fileExists(atPath: fallback.path) {
                try fm.removeItem(at: fallback)
            }
        }

        let remaining = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard !remaining.isEmpty else {
            try fm.removeItem(at: archiveURL)
            return
        }

        let settings = CompressionSettings(
            format: format,
            archiveName: archiveURL.lastPathComponent,
            exclusionPatterns: [],
            password: password
        )

        try await create(
            from: remaining,
            to: newArchiveURL,
            settings: settings,
            onProgress: { _ in }
        )

        try Bento7zPathSafety.replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
    }

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        password: String? = nil,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        guard !sourceURLs.isEmpty else {
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed(
                String(localized: "Read-only archive formats cannot be modified.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }

        let fm = FileManager.default
        if prefersBinaryServer && Self.supportsInPlaceEdit(format) {
            do {
                try await addInPlaceBinary(to: archiveURL, format: format, from: sourceURLs, password: password, onProgress: onProgress)
                cacheManager.invalidate(for: archiveURL)
                onProgress(ArchiveProgress(fractionCompleted: 1.0))
                return
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error, code == "UNSUPPORTED_INPLACE" {
                    // Fall back to atomic extract-and-rebuild.
                } else {
                    throw error
                }
            }
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_add_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: password,
            onProgress: { update in
                onProgress(ArchiveProgress(
                    fractionCompleted: update.fractionCompleted * 0.4,
                    currentFile: update.currentFile
                ))
            }
        )

        for sourceURL in sourceURLs {
            try Task.checkCancellation()
            let destURL = extractDir.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        }

        let allContents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let settings = CompressionSettings(
            format: format,
            archiveName: archiveURL.lastPathComponent,
            exclusionPatterns: [],
            password: password
        )

        try await create(
            from: allContents,
            to: newArchiveURL,
            settings: settings,
            onProgress: { update in
                onProgress(ArchiveProgress(
                    fractionCompleted: 0.4 + update.fractionCompleted * 0.6,
                    currentFile: update.currentFile
                ))
            }
        )

        try Bento7zPathSafety.replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
        cacheManager.invalidate(for: archiveURL)
        onProgress(ArchiveProgress(fractionCompleted: 1.0))
    }

    // MARK: - Native In-Place Binary Worker Mutations (ZIP / 7z / TAR)

    private static func supportsInPlaceEdit(_ format: ArchiveFormat) -> Bool {
        switch format {
        case .zip, .sevenZip, .tar:
            return true
        case .tarGz, .tarBz2, .tarXz:
            return false
        }
    }

    private func addInPlaceBinary(
        to archiveURL: URL,
        format: ArchiveFormat,
        from sourceURLs: [URL],
        password: String?,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws {
        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "add"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeAddRequest(
            archivePath: archiveURL.path,
            password: password,
            format: format.bento7zFormatName,
            paths: sourceURLs.map(\.path)
        )
        _ = try await worker.sendRequest(
            type: .add,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: { progress in
                onProgress(Self.archiveProgress(from: progress))
            }
        )
    }

    private func deleteInPlaceBinary(
        from archiveURL: URL,
        format: ArchiveFormat,
        entries: [FileEntry],
        password: String?
    ) async throws {
        var sanitizedPaths: [String] = []
        sanitizedPaths.reserveCapacity(entries.count)
        for entry in entries {
            let relPath = Bento7zPathSafety.archiveRelativePath(for: entry)
            let safePath = try Bento7zPathSafety.sanitizedRelativePath(relPath)
            sanitizedPaths.append(safePath)
        }
        guard !sanitizedPaths.isEmpty else { return }

        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "delete"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeDeleteRequest(
            archivePath: archiveURL.path,
            password: password,
            format: format.bento7zFormatName,
            entries: sanitizedPaths
        )
        _ = try await worker.sendRequest(
            type: .delete,
            payload: payload,
            hardKillOnCancel: true
        )
    }
}
