import Foundation

/// Path traversal validation and atomic archive replacement helpers for `Bento7zEngine`.
enum Bento7zPathSafety {

    static func sanitizedRelativePath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0") else {
            throw Bento7zError.operationFailed(
                String(localized: "Invalid archive path: \(rawPath)", bundle: .module),
                "INVALID_PATH"
            )
        }
        if normalized.count >= 2,
           let first = normalized.first, first.isLetter,
           normalized[normalized.index(after: normalized.startIndex)] == ":" {
            throw Bento7zError.operationFailed(
                String(localized: "Invalid archive path: \(rawPath)", bundle: .module),
                "INVALID_PATH"
            )
        }
        var components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("..") else {
            throw Bento7zError.operationFailed(
                String(localized: "Path traversal detected: \(rawPath)", bundle: .module),
                "INVALID_PATH"
            )
        }
        while components.first == "." {
            components.removeFirst()
        }
        guard !components.isEmpty else {
            throw Bento7zError.operationFailed(
                String(localized: "Invalid archive path: \(rawPath)", bundle: .module),
                "INVALID_PATH"
            )
        }
        return components.joined(separator: "/")
    }

    static func verifiedDescendantURL(relativePath: String, baseDirectory: URL) throws -> URL {
        let safeRel = try sanitizedRelativePath(relativePath)
        let basePath = baseDirectory.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetURL = baseDirectory.appendingPathComponent(safeRel)
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(basePrefix) else {
            throw Bento7zError.operationFailed(
                String(localized: "Destination path escapes target directory: \(relativePath)", bundle: .module),
                "INVALID_PATH"
            )
        }
        return targetURL
    }

    static func replaceArchiveAtomically(at archiveURL: URL, with newArchiveURL: URL, tempDir: URL) throws {
        let fm = FileManager.default
        let backupURL = tempDir.appendingPathComponent("backup_\(archiveURL.lastPathComponent)")
        try fm.moveItem(at: archiveURL, to: backupURL)
        do {
            try fm.moveItem(at: newArchiveURL, to: archiveURL)
            try? fm.removeItem(at: backupURL)
        } catch {
            try? fm.removeItem(at: archiveURL)
            try fm.moveItem(at: backupURL, to: archiveURL)
            throw error
        }
    }

    static func archiveRelativePath(for entry: FileEntry) -> String {
        if let rel = entry.archiveRelativePath, !rel.isEmpty {
            return rel
        }
        let fullPath = entry.url.path
        if fullPath.hasPrefix("/archive-root/") {
            return String(fullPath.dropFirst("/archive-root/".count))
        }
        return fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
    }

    static func collectArchivePaths(from entries: [FileEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func walk(_ entry: FileEntry) {
            let path = archiveRelativePath(for: entry)
            if !path.isEmpty && seen.insert(path).inserted {
                result.append(path)
            }
            if let children = entry.children {
                for child in children {
                    walk(child)
                }
            }
        }

        for entry in entries {
            walk(entry)
        }
        return result
    }
}
