import SwiftUI
import Observation

@Observable
@MainActor
public class AppState {
    public var mode: ArchiveMode = .empty

    public var fileEntries: [FileEntry] = []

    public var navigationPath: [FileEntry] = []

    public var selectedEntryIDs: Set<UUID> = []

    public var displayedEntries: [FileEntry] {
        if let last = navigationPath.last {
            return last.children ?? []
        }
        return fileEntries
    }

    public var compressionSettings = CompressionSettings()

    public var showInspector: Bool = false

    public var sourceArchiveURL: URL?

    public var lastError: String?

    public var archiveEngine: ArchiveEngine?

    public var coordinator = CompressionCoordinator()
    public var preferencesManager: PreferencesManager?

    public init() {}

    public func applyPreferences() {
        guard let prefs = preferencesManager?.loadPreferences() else { return }
        preferencesManager?.applyDefaults(to: &compressionSettings, from: prefs)
    }

    public func loadFiles(from urls: [URL]) {
        var entries: [FileEntry] = []
        for url in urls {
            let entry = createEntry(for: url)
            entries.append(entry)
        }
        fileEntries = entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        mode = .compress
        showInspector = true
    }

    public func loadArchive(from url: URL) {
        mode = .browseArchive
        sourceArchiveURL = url
    }

    public func navigateInto(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        navigationPath.append(entry)
        selectedEntryIDs.removeAll()
    }

    public func navigateBack(to level: Int = 0) {
        if level <= 0 {
            navigationPath.removeAll()
        } else {
            let safeLevel = min(level, navigationPath.count)
            navigationPath.removeLast(navigationPath.count - safeLevel)
        }
        selectedEntryIDs.removeAll()
    }

    public func removeEntries(at offsets: IndexSet) {
        if mode == .browseArchive {
            return
        }
        fileEntries.remove(atOffsets: offsets)
    }

    public func removeSelectedEntries() {
        if mode == .browseArchive {
            return
        }
        fileEntries.removeAll { selectedEntryIDs.contains($0.id) }
        selectedEntryIDs.removeAll()
    }

    public func addEntries(from urls: [URL]) {
        var newEntries: [FileEntry] = []
        for url in urls {
            let entry = createEntry(for: url)
            newEntries.append(entry)
        }
        fileEntries.append(contentsOf: newEntries)
        fileEntries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func reset() {
        mode = .empty
        fileEntries = []
        navigationPath = []
        selectedEntryIDs = []
        compressionSettings = CompressionSettings()
        showInspector = false
        sourceArchiveURL = nil
        lastError = nil
    }

    private func createEntry(for url: URL) -> FileEntry {
        let isDir = FileUtils.isDirectory(at: url)
        let children: [FileEntry]?
        if isDir {
            children = loadChildren(for: url)
        } else {
            children = nil
        }
        return FileEntry(
            url: url,
            name: FileUtils.displayName(for: url),
            isDirectory: isDir,
            size: FileUtils.fileSize(at: url),
            modificationDate: FileUtils.fileModificationDate(at: url),
            isFromArchive: false,
            children: children
        )
    }

    private func loadChildren(for url: URL) -> [FileEntry] {
        let contents = FileUtils.enumerateDirectory(at: url)
        return contents.map { childURL in
            let childIsDir = FileUtils.isDirectory(at: childURL)
            let grandChildren: [FileEntry]?
            if childIsDir {
                grandChildren = loadChildren(for: childURL)
            } else {
                grandChildren = nil
            }
            return FileEntry(
                url: childURL,
                name: FileUtils.displayName(for: childURL),
                isDirectory: childIsDir,
                size: FileUtils.fileSize(at: childURL),
                modificationDate: FileUtils.fileModificationDate(at: childURL),
                isFromArchive: false,
                children: grandChildren
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}