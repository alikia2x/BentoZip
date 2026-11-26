import AppKit
import Darwin
import Foundation

/// Represents a temporary file extracted from a writable archive that was modified externally.
public struct PendingExternalEdit: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let tempURL: URL
    public let archiveURL: URL
    public let archiveRelativePath: String
    public let fileName: String
    public let detectedAt: Date

    public init(
        id: UUID = UUID(),
        tempURL: URL,
        archiveURL: URL,
        archiveRelativePath: String,
        fileName: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.tempURL = tempURL
        self.archiveURL = archiveURL
        self.archiveRelativePath = archiveRelativePath
        self.fileName = fileName
        self.detectedAt = detectedAt
    }
}

/// Watches temporary files opened from writable archives and notifies when modified by external apps.
@MainActor
public final class ExternalEditMonitor {
    private struct FileFingerprint: Equatable {
        let modTimeSec: Int
        let modTimeNsec: Int
        let size: Int64
    }

    private final class WatchEntry {
        let tempURL: URL
        let archiveURL: URL
        let archiveRelativePath: String
        let password: String?
        var lastFingerprint: FileFingerprint?
        var source: DispatchSourceFileSystemObject?
        var pendingReattach = false

        init(
            tempURL: URL,
            archiveURL: URL,
            archiveRelativePath: String,
            password: String?,
            lastFingerprint: FileFingerprint?
        ) {
            self.tempURL = tempURL
            self.archiveURL = archiveURL
            self.archiveRelativePath = archiveRelativePath
            self.password = password
            self.lastFingerprint = lastFingerprint
        }

        func cancelSource() {
            source?.cancel()
            source = nil
        }
    }

    private var entriesByPath: [String: WatchEntry] = [:]
    private var activeObserver: NSObjectProtocol?
    public var onModified: (@MainActor (PendingExternalEdit) -> Void)?

    public init(onModified: (@MainActor (PendingExternalEdit) -> Void)? = nil) {
        self.onModified = onModified
        self.activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAllWatchedFiles()
            }
        }
    }

    deinit {
        for entry in entriesByPath.values {
            entry.source?.cancel()
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    /// Start watching `tempURL` for external edits tied back to `archiveRelativePath` inside `archiveURL`.
    public func watch(
        tempURL: URL,
        archiveURL: URL,
        archiveRelativePath: String,
        password: String?
    ) {
        let key = tempURL.standardizedFileURL.path
        entriesByPath[key]?.cancelSource()

        let fingerprint = Self.readFingerprint(at: tempURL)
        let entry = WatchEntry(
            tempURL: tempURL,
            archiveURL: archiveURL,
            archiveRelativePath: archiveRelativePath,
            password: password,
            lastFingerprint: fingerprint
        )
        entriesByPath[key] = entry
        attachSource(for: entry, key: key)
    }

    /// Update baseline metadata after a file is saved back or dismissed so the same write isn't re-reported.
    public func acknowledgeChange(at tempURL: URL) {
        let key = tempURL.standardizedFileURL.path
        guard let entry = entriesByPath[key] else { return }
        entry.lastFingerprint = Self.readFingerprint(at: tempURL)
        if entry.source == nil {
            attachSource(for: entry, key: key)
        }
    }

    public func stopWatching(tempURL: URL) {
        let key = tempURL.standardizedFileURL.path
        entriesByPath.removeValue(forKey: key)?.cancelSource()
    }

    public func stopWatching(forArchive archiveURL: URL) {
        let target = archiveURL.standardizedFileURL.path
        let keys = entriesByPath.compactMap { key, entry in
            entry.archiveURL.standardizedFileURL.path == target ? key : nil
        }
        for key in keys {
            entriesByPath.removeValue(forKey: key)?.cancelSource()
        }
    }

    public func stopAll() {
        for entry in entriesByPath.values {
            entry.cancelSource()
        }
        entriesByPath.removeAll()
    }

    public func checkAllWatchedFiles() {
        for (key, entry) in entriesByPath {
            evaluateChange(for: entry, key: key, reattachSource: entry.source == nil)
        }
    }

    // MARK: - DispatchSource File System Monitoring

    private func attachSource(for entry: WatchEntry, key: String) {
        entry.cancelSource()
        let fd = Darwin.open(entry.tempURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak entry] in
            guard let self, let entry, self.entriesByPath[key] === entry else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                self.scheduleReattachAndCheck(for: entry, key: key)
            } else {
                self.evaluateChange(for: entry, key: key, reattachSource: false)
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        entry.source = source
        source.resume()
    }

    private func scheduleReattachAndCheck(for entry: WatchEntry, key: String) {
        guard !entry.pendingReattach else { return }
        entry.pendingReattach = true
        entry.cancelSource()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak entry] in
            guard let self, let entry, self.entriesByPath[key] === entry else { return }
            entry.pendingReattach = false
            self.evaluateChange(for: entry, key: key, reattachSource: true)
        }
    }

    private func evaluateChange(for entry: WatchEntry, key: String, reattachSource: Bool) {
        if reattachSource {
            attachSource(for: entry, key: key)
        }
        guard let current = Self.readFingerprint(at: entry.tempURL) else {
            return
        }
        guard current != entry.lastFingerprint else {
            return
        }
        entry.lastFingerprint = current
        let edit = PendingExternalEdit(
            tempURL: entry.tempURL,
            archiveURL: entry.archiveURL,
            archiveRelativePath: entry.archiveRelativePath,
            fileName: entry.tempURL.lastPathComponent
        )
        onModified?(edit)
    }

    private static func readFingerprint(at url: URL) -> FileFingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileFingerprint(
            modTimeSec: st.st_mtimespec.tv_sec,
            modTimeNsec: st.st_mtimespec.tv_nsec,
            size: Int64(st.st_size)
        )
    }
}
