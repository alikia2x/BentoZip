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
        try await addEntries(
            to: archiveURL,
            from: sourceURLs,
            targetPrefix: nil,
            password: password,
            onProgress: onProgress
        )
    }

    public func addEntries(
        to archiveURL: URL,
        from sourceURLs: [URL],
        targetPrefix: String?,
        password: String?,
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

        let safePrefix: String?
        if let rawPrefix = targetPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPrefix.isEmpty {
            safePrefix = try Bento7zPathSafety.validatedRelativePath(rawPrefix)
        } else {
            safePrefix = nil
        }

        let fm = FileManager.default
        if !prefersBinaryServer {
            var params: [String: Any] = [
                "archive": archiveURL.path,
                "format": format.bento7zFormatName,
                "paths": sourceURLs.map(\.path)
            ]
            if let password, !password.isEmpty {
                params["password"] = password
            }
            if let safePrefix {
                params["target_prefix"] = safePrefix
            }
            _ = try await runner.execute(command: "add", params: params, onProgress: onProgress)
            cacheManager.invalidate(for: archiveURL)
            onProgress(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        if Self.supportsInPlaceEdit(format) {
            do {
                try await addInPlaceBinary(
                    to: archiveURL,
                    format: format,
                    from: sourceURLs,
                    targetPrefix: safePrefix,
                    password: password,
                    onProgress: onProgress
                )
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

        let targetBaseDir: URL
        if let safePrefix {
            targetBaseDir = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safePrefix, baseDirectory: extractDir)
            try fm.createDirectory(at: targetBaseDir, withIntermediateDirectories: true)
        } else {
            targetBaseDir = extractDir
        }

        for sourceURL in sourceURLs {
            try Task.checkCancellation()
            let destURL = targetBaseDir.appendingPathComponent(sourceURL.lastPathComponent)
            if Bento7zPathSafety.itemExists(at: destURL) {
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

    public func renameEntry(
        in archiveURL: URL,
        from oldPath: String,
        to newPath: String,
        password: String? = nil,
        onProgress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws {
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed(
                String(localized: "Read-only archive formats cannot be modified.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }

        let safeOldPath = try Bento7zPathSafety.validatedRelativePath(oldPath)
        let safeNewPath = try Bento7zPathSafety.validatedRelativePath(newPath)
        guard safeOldPath != safeNewPath else {
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        if !prefersBinaryServer {
            var params: [String: Any] = [
                "archive": archiveURL.path,
                "format": format.bento7zFormatName,
                "old_path": safeOldPath,
                "new_path": safeNewPath
            ]
            if let password, !password.isEmpty {
                params["password"] = password
            }
            _ = try await runner.execute(command: "rename", params: params, onProgress: onProgress)
            cacheManager.invalidate(for: archiveURL)
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        if Self.supportsInPlaceEdit(format) {
            do {
                try await renameInPlaceBinary(
                    in: archiveURL,
                    format: format,
                    oldPath: safeOldPath,
                    newPath: safeNewPath,
                    password: password,
                    onProgress: onProgress
                )
                cacheManager.invalidate(for: archiveURL)
                onProgress?(ArchiveProgress(fractionCompleted: 1.0))
                return
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error, code == "UNSUPPORTED_INPLACE" {
                    // Fall back to atomic extract-and-rebuild.
                } else {
                    throw error
                }
            }
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_rename_\(UUID().uuidString)")
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
                onProgress?(ArchiveProgress(
                    fractionCompleted: update.fractionCompleted * 0.4,
                    currentFile: update.currentFile
                ))
            }
        )

        let srcURL = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safeOldPath, baseDirectory: extractDir)
        let dstURL = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safeNewPath, baseDirectory: extractDir)
        let srcStatus = Bento7zPathSafety.itemStatus(at: srcURL)
        guard srcStatus.exists else {
            throw Bento7zError.fileNotFound(safeOldPath)
        }
        try fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let dstStatus = Bento7zPathSafety.itemStatus(at: dstURL)
        if dstStatus.exists {
            let isSameInodeCaseRename = (srcStatus.device == dstStatus.device && srcStatus.inode == dstStatus.inode)
            if !isSameInodeCaseRename {
                throw Bento7zError.conflict(
                    String(localized: "Destination already exists: \(safeNewPath)", bundle: .module)
                )
            }
        }
        try fm.moveItem(at: srcURL, to: dstURL)

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
                onProgress?(ArchiveProgress(
                    fractionCompleted: 0.4 + update.fractionCompleted * 0.6,
                    currentFile: update.currentFile
                ))
            }
        )

        try Bento7zPathSafety.replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
        cacheManager.invalidate(for: archiveURL)
        onProgress?(ArchiveProgress(fractionCompleted: 1.0))
    }

    public func moveEntries(
        in archiveURL: URL,
        entries: [FileEntry],
        toTargetDir targetDir: String,
        password: String? = nil,
        onProgress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws {
        guard !entries.isEmpty else {
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        }
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed(
                String(localized: "Read-only archive formats cannot be modified.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }

        let cleanTargetDir: String
        let trimmedTarget = targetDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTarget.isEmpty {
            cleanTargetDir = ""
        } else {
            cleanTargetDir = try Bento7zPathSafety.validatedRelativePath(trimmedTarget)
        }

        var safePaths: [String] = []
        safePaths.reserveCapacity(entries.count)
        for entry in entries {
            let raw = Bento7zPathSafety.archiveRelativePath(for: entry)
            let safe = try Bento7zPathSafety.validatedRelativePath(raw)
            if !cleanTargetDir.isEmpty && (cleanTargetDir == safe || cleanTargetDir.hasPrefix(safe + "/")) {
                throw Bento7zError.operationFailed(
                    String(localized: "Cannot move an item into itself or its subfolder.", bundle: .module),
                    "INVALID_PATH"
                )
            }
            safePaths.append(safe)
        }

        if !prefersBinaryServer {
            var params: [String: Any] = [
                "archive": archiveURL.path,
                "format": format.bento7zFormatName,
                "entries": safePaths,
                "target_dir": cleanTargetDir
            ]
            if let password, !password.isEmpty {
                params["password"] = password
            }
            _ = try await runner.execute(command: "move", params: params, onProgress: onProgress)
            cacheManager.invalidate(for: archiveURL)
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        if Self.supportsInPlaceEdit(format) {
            do {
                try await moveInPlaceBinary(
                    in: archiveURL,
                    format: format,
                    entries: safePaths,
                    targetDir: cleanTargetDir,
                    password: password,
                    onProgress: onProgress
                )
                cacheManager.invalidate(for: archiveURL)
                onProgress?(ArchiveProgress(fractionCompleted: 1.0))
                return
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error, code == "UNSUPPORTED_INPLACE" {
                    // Fall back to atomic extract-and-rebuild.
                } else {
                    throw error
                }
            }
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_move_\(UUID().uuidString)")
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
                onProgress?(ArchiveProgress(
                    fractionCompleted: update.fractionCompleted * 0.4,
                    currentFile: update.currentFile
                ))
            }
        )

        let targetBaseURL: URL
        if cleanTargetDir.isEmpty {
            targetBaseURL = extractDir
        } else {
            targetBaseURL = try Bento7zPathSafety.verifiedDescendantURL(relativePath: cleanTargetDir, baseDirectory: extractDir)
            try fm.createDirectory(at: targetBaseURL, withIntermediateDirectories: true)
        }

        for safePath in safePaths {
            try Task.checkCancellation()
            let srcURL = try Bento7zPathSafety.verifiedDescendantURL(relativePath: safePath, baseDirectory: extractDir)
            let srcStatus = Bento7zPathSafety.itemStatus(at: srcURL)
            guard srcStatus.exists else {
                throw Bento7zError.fileNotFound(safePath)
            }
            let dstURL = targetBaseURL.appendingPathComponent(srcURL.lastPathComponent)
            let dstStatus = Bento7zPathSafety.itemStatus(at: dstURL)
            if dstStatus.exists {
                if srcStatus.device == dstStatus.device && srcStatus.inode == dstStatus.inode {
                    continue
                }
                throw Bento7zError.conflict(
                    String(localized: "Destination already exists: \(srcURL.lastPathComponent)", bundle: .module)
                )
            }
            try fm.moveItem(at: srcURL, to: dstURL)
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
                onProgress?(ArchiveProgress(
                    fractionCompleted: 0.4 + update.fractionCompleted * 0.6,
                    currentFile: update.currentFile
                ))
            }
        )

        try Bento7zPathSafety.replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
        cacheManager.invalidate(for: archiveURL)
        onProgress?(ArchiveProgress(fractionCompleted: 1.0))
    }

    public func updatePassword(
        in archiveURL: URL,
        oldPassword: String? = nil,
        newPassword: String?,
        encryptionMethod: String? = nil,
        encryptHeaders: Bool = true,
        onProgress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws {
        guard let format = FormatDetector.detectFormat(of: archiveURL) else {
            throw Bento7zError.operationFailed(
                String(localized: "Read-only archive formats cannot be modified.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }
        guard format.supportsPassword else {
            throw Bento7zError.operationFailed(
                String(localized: "Password protection is only supported for ZIP and 7z archives.", bundle: .module),
                "UNSUPPORTED_FORMAT"
            )
        }

        let effectiveNewPassword = (newPassword?.isEmpty == false) ? newPassword : nil
        let effectiveEncMethod = (format == .zip && effectiveNewPassword != nil)
            ? (encryptionMethod ?? ZipEncryptionMethod.aes256.bento7zValue)
            : nil

        if !prefersBinaryServer {
            var params: [String: Any] = [
                "archive": archiveURL.path,
                "format": format.bento7zFormatName,
                "encrypt_headers": encryptHeaders
            ]
            if let oldPassword, !oldPassword.isEmpty {
                params["old_password"] = oldPassword
            }
            if let effectiveNewPassword {
                params["new_password"] = effectiveNewPassword
            }
            if let effectiveEncMethod {
                params["encryption_method"] = effectiveEncMethod
            }
            _ = try await runner.execute(command: "update_password", params: params, onProgress: onProgress)
            cacheManager.invalidate(for: archiveURL)
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        }

        do {
            try await updatePasswordBinary(
                in: archiveURL,
                format: format,
                oldPassword: oldPassword,
                newPassword: effectiveNewPassword,
                encryptionMethod: effectiveEncMethod,
                encryptHeaders: encryptHeaders,
                onProgress: onProgress
            )
            cacheManager.invalidate(for: archiveURL)
            onProgress?(ArchiveProgress(fractionCompleted: 1.0))
            return
        } catch let error as Bento7zError {
            if case .operationFailed(_, let code) = error, code == "UNSUPPORTED_INPLACE" {
                // Fall back to atomic extract-and-recompress.
            } else {
                throw error
            }
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BentoZip_pw_\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extracted")
        let newArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        try await extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: oldPassword,
            onProgress: { update in
                onProgress?(ArchiveProgress(
                    fractionCompleted: update.fractionCompleted * 0.45,
                    currentFile: update.currentFile
                ))
            }
        )

        let allContents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let zipMethod: ZipEncryptionMethod = (effectiveEncMethod == ZipEncryptionMethod.zipCrypto.bento7zValue)
            ? .zipCrypto
            : .aes256
        let settings = CompressionSettings(
            format: format,
            archiveName: archiveURL.lastPathComponent,
            exclusionPatterns: [],
            password: effectiveNewPassword,
            zipEncryptionMethod: zipMethod,
            encryptHeaders: encryptHeaders
        )

        try await create(
            from: allContents,
            to: newArchiveURL,
            settings: settings,
            onProgress: { update in
                onProgress?(ArchiveProgress(
                    fractionCompleted: 0.45 + update.fractionCompleted * 0.55,
                    currentFile: update.currentFile
                ))
            }
        )

        try Bento7zPathSafety.replaceArchiveAtomically(at: archiveURL, with: newArchiveURL, tempDir: tempDir)
        cacheManager.invalidate(for: archiveURL)
        onProgress?(ArchiveProgress(fractionCompleted: 1.0))
    }

    // MARK: - Native In-Place Binary Worker Mutations (ZIP / 7z / TAR)

    private static func supportsInPlaceEdit(_ format: ArchiveFormat) -> Bool {
        switch format {
        case .zip, .sevenZip, .tar:
            return true
        case .tarGz, .tarBz2, .tarXz, .tarZstd, .zstd, .dmg, .aar:
            return false
        }
    }

    private func addInPlaceBinary(
        to archiveURL: URL,
        format: ArchiveFormat,
        from sourceURLs: [URL],
        targetPrefix: String?,
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
            paths: sourceURLs.map(\.path),
            targetPrefix: targetPrefix
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

    private func renameInPlaceBinary(
        in archiveURL: URL,
        format: ArchiveFormat,
        oldPath: String,
        newPath: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "rename"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeRenameRequest(
            archivePath: archiveURL.path,
            password: password,
            format: format.bento7zFormatName,
            oldPath: oldPath,
            newPath: newPath
        )
        let progressForwarder: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)? = onProgress.map { callback in
            { @Sendable progress in
                callback(Self.archiveProgress(from: progress))
            }
        }
        _ = try await worker.sendRequest(
            type: .rename,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: progressForwarder
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

    private func moveInPlaceBinary(
        in archiveURL: URL,
        format: ArchiveFormat,
        entries: [String],
        targetDir: String,
        password: String?,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "move"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeMoveRequest(
            archivePath: archiveURL.path,
            password: password,
            format: format.bento7zFormatName,
            entries: entries,
            targetDir: targetDir
        )
        let progressForwarder: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)? = onProgress.map { callback in
            { @Sendable progress in
                callback(Self.archiveProgress(from: progress))
            }
        }
        _ = try await worker.sendRequest(
            type: .move,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: progressForwarder
        )
    }

    private func updatePasswordBinary(
        in archiveURL: URL,
        format: ArchiveFormat,
        oldPassword: String?,
        newPassword: String?,
        encryptionMethod: String?,
        encryptHeaders: Bool,
        onProgress: (@Sendable (ArchiveProgress) -> Void)?
    ) async throws {
        let worker = Bento7zBinaryClient(
            binaryPath: runner.binaryPath,
            libraryPath: runner.libraryPath,
            label: "updatePassword"
        )
        defer { worker.shutdown(terminateProcess: true) }

        let payload = Bento7zBinaryProtocol.encodeUpdatePasswordRequest(
            archivePath: archiveURL.path,
            oldPassword: oldPassword,
            newPassword: newPassword,
            format: format.bento7zFormatName,
            encryptionMethod: encryptionMethod,
            encryptHeaders: encryptHeaders
        )
        let progressForwarder: (@Sendable (Bento7zBinaryProtocol.ProgressPayload) -> Void)? = onProgress.map { callback in
            { @Sendable progress in
                callback(Self.archiveProgress(from: progress))
            }
        }
        _ = try await worker.sendRequest(
            type: .updatePassword,
            payload: payload,
            hardKillOnCancel: true,
            onProgress: progressForwarder
        )
    }
}
