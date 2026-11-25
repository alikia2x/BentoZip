import Foundation

/// Persistent LRU disk cache stored under `~/Library/Caches` for unwrapped `.tar` streams
/// of compound archives (`.tar.gz`, `.tar.bz2`, `.tar.xz`).
/// Encrypted archives are never cached on disk.
public final class ArchiveCacheManager: @unchecked Sendable {
    public static let shared = ArchiveCacheManager()

    public struct CacheStats: Sendable, Equatable {
        public let totalBytes: Int64
        public let entryCount: Int

        public init(totalBytes: Int64, entryCount: Int) {
            self.totalBytes = totalBytes
            self.entryCount = entryCount
        }
    }

    private struct Manifest: Codable {
        var entries: [String: CacheEntry] = [:]
    }

    private struct CacheEntry: Codable {
        let key: String
        let fileName: String
        let archivePath: String
        let archiveSize: Int64
        let archiveMtime: Double
        let archiveInode: UInt64
        var cachedBytes: Int64
        var lastAccessedAt: Double
    }

    private let cacheDirectory: URL
    private let manifestURL: URL
    private let lock = NSLock()
    private var maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024 // Default 2 GB

    public init(directory: URL? = nil, maxCacheMB: Int = 2048) {
        if let directory {
            self.cacheDirectory = directory
        } else {
            let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheDirectory = cachesBase
                .appendingPathComponent("com.bentozip.BentoZip", isDirectory: true)
                .appendingPathComponent("ArchiveCache", isDirectory: true)
        }
        self.manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
        self.maxCacheBytes = Int64(max(0, maxCacheMB)) * 1024 * 1024
    }

    public func setMaxCacheSizeMB(_ megabytes: Int) {
        lock.withLock {
            maxCacheBytes = Int64(max(0, megabytes)) * 1024 * 1024
            if maxCacheBytes == 0 {
                clearCacheLocked()
            } else {
                var manifest = loadManifestLocked()
                evictIfNeededLocked(&manifest, reserveBytes: 0)
                saveManifestLocked(manifest)
            }
        }
    }

    public func currentMaxCacheSizeMB() -> Int {
        lock.withLock { Int(maxCacheBytes / (1024 * 1024)) }
    }

    /// Returns a deterministic cache file URL for a non-encrypted compound `.tar.*` archive
    /// if persistent caching is enabled and disk space allows; otherwise `nil`.
    public func tarCacheURL(for archiveURL: URL, isEncrypted: Bool = false) -> URL? {
        guard !isEncrypted else { return nil }
        guard Self.isCompoundTarArchive(archiveURL) else { return nil }

        return lock.withLock {
            guard maxCacheBytes > 0 else { return nil }
            guard let metadata = Self.fileMetadata(for: archiveURL) else { return nil }

            // Avoid caching archives whose compressed size alone exceeds half the cache quota
            // or would risk crowding available disk space.
            if metadata.size > maxCacheBytes / 2 {
                return nil
            }
            if let freeBytes = Self.availableDiskSpace(at: cacheDirectory),
               metadata.size * 4 > freeBytes / 4 {
                return nil
            }

            ensureDirectoryLocked()
            let key = Self.cacheKey(for: archiveURL, metadata: metadata)
            var manifest = loadManifestLocked()

            // Invalidate any stale entries for the same archive path with older mtime/size/inode.
            let standardizedPath = archiveURL.standardizedFileURL.path
            let staleKeys = manifest.entries.values
                .filter { $0.archivePath == standardizedPath && $0.key != key }
                .map(\.key)
            for staleKey in staleKeys {
                removeEntryLocked(key: staleKey, from: &manifest)
            }

            let fileName = "\(key).tar"
            let targetURL = cacheDirectory.appendingPathComponent(fileName)

            if var existing = manifest.entries[key] {
                if FileManager.default.fileExists(atPath: targetURL.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
                   let cachedSize = (attrs[.size] as? NSNumber)?.int64Value,
                   cachedSize > 0 {
                    existing.cachedBytes = cachedSize
                    existing.lastAccessedAt = Date().timeIntervalSince1970
                    manifest.entries[key] = existing
                    saveManifestLocked(manifest)
                    return targetURL
                } else {
                    manifest.entries.removeValue(forKey: key)
                    saveManifestLocked(manifest)
                }
            }

            // Prepare room up front based on conservative estimate before backend writes the file.
            evictIfNeededLocked(&manifest, reserveBytes: min(metadata.size * 3, maxCacheBytes / 2))
            saveManifestLocked(manifest)
            return targetURL
        }
    }

    /// Record a freshly materialized `.tar` cache file and enforce LRU size limits.
    public func recordMaterializedTar(for archiveURL: URL, at cacheURL: URL) {
        lock.withLock {
            guard let metadata = Self.fileMetadata(for: archiveURL) else { return }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                  let cachedSize = (attrs[.size] as? NSNumber)?.int64Value,
                  cachedSize > 0 else {
                return
            }

            // If the actual uncompressed .tar exceeds the total quota, delete it instead of keeping an oversized entry.
            if maxCacheBytes <= 0 || cachedSize > maxCacheBytes {
                try? FileManager.default.removeItem(at: cacheURL)
                return
            }

            let key = Self.cacheKey(for: archiveURL, metadata: metadata)
            var manifest = loadManifestLocked()
            manifest.entries[key] = CacheEntry(
                key: key,
                fileName: cacheURL.lastPathComponent,
                archivePath: archiveURL.standardizedFileURL.path,
                archiveSize: metadata.size,
                archiveMtime: metadata.mtime,
                archiveInode: metadata.inode,
                cachedBytes: cachedSize,
                lastAccessedAt: Date().timeIntervalSince1970
            )
            evictIfNeededLocked(&manifest, reserveBytes: 0)
            saveManifestLocked(manifest)
        }
    }

    /// Remove any cached files associated with `archiveURL` (e.g. after archive mutation).
    public func invalidate(for archiveURL: URL) {
        let standardizedPath = archiveURL.standardizedFileURL.path
        lock.withLock {
            var manifest = loadManifestLocked()
            let matchingKeys = manifest.entries.values
                .filter { $0.archivePath == standardizedPath }
                .map(\.key)
            guard !matchingKeys.isEmpty else { return }
            for key in matchingKeys {
                removeEntryLocked(key: key, from: &manifest)
            }
            saveManifestLocked(manifest)
        }
    }

    /// Compute current cache disk usage and entry count.
    public func stats() -> CacheStats {
        lock.withLock {
            var manifest = loadManifestLocked()
            var totalBytes: Int64 = 0
            var count = 0
            var dirty = false
            let fm = FileManager.default

            for (key, entry) in manifest.entries {
                let fileURL = cacheDirectory.appendingPathComponent(entry.fileName)
                if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value {
                    totalBytes += size
                    count += 1
                } else {
                    manifest.entries.removeValue(forKey: key)
                    dirty = true
                }
            }
            if dirty {
                saveManifestLocked(manifest)
            }
            return CacheStats(totalBytes: totalBytes, entryCount: count)
        }
    }

    /// Delete all cached files and reset the manifest.
    public func clearCache() {
        lock.withLock {
            clearCacheLocked()
        }
    }

    // MARK: - Internals

    private struct FileMeta {
        let size: Int64
        let mtime: Double
        let inode: UInt64
    }

    private static func isCompoundTarArchive(_ url: URL) -> Bool {
        guard let format = FormatDetector.detectReadableFormat(of: url) else { return false }
        switch format {
        case .tarGz, .tarBz2, .tarXz, .gz, .bz2, .xz:
            return true
        default:
            return false
        }
    }

    private static func fileMetadata(for url: URL) -> FileMeta? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return FileMeta(size: size, mtime: mtime, inode: inode)
    }

    private static func availableDiskSpace(at url: URL) -> Int64? {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let standard = values?.volumeAvailableCapacity {
            return Int64(standard)
        }
        return nil
    }

    private static func cacheKey(for url: URL, metadata: FileMeta) -> String {
        let raw = "\(url.standardizedFileURL.path)|\(metadata.size)|\(Int64(metadata.mtime * 1000))|\(metadata.inode)"
        // FNV-1a 64-bit hash produces clean, fixed-length filesystem-safe cache keys.
        var hash: UInt64 = 14695981039346656037
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func ensureDirectoryLocked() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func loadManifestLocked() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return Manifest()
        }
        return manifest
    }

    private func saveManifestLocked(_ manifest: Manifest) {
        ensureDirectoryLocked()
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private func removeEntryLocked(key: String, from manifest: inout Manifest) {
        if let removed = manifest.entries.removeValue(forKey: key) {
            let fileURL = cacheDirectory.appendingPathComponent(removed.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func evictIfNeededLocked(_ manifest: inout Manifest, reserveBytes: Int64) {
        let limit = max(0, maxCacheBytes - reserveBytes)
        var total = manifest.entries.values.reduce(Int64(0)) { $0 + $1.cachedBytes }
        guard total > limit else { return }

        let oldestFirst = manifest.entries.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        for entry in oldestFirst {
            guard total > limit else { break }
            removeEntryLocked(key: entry.key, from: &manifest)
            total -= entry.cachedBytes
        }
    }

    private func clearCacheLocked() {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for item in contents {
                try? fm.removeItem(at: item)
            }
        }
    }
}
