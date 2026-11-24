import AppKit
import UniformTypeIdentifiers

extension CompressionCoordinator {

    func resolveCompressSaveURL(sourceURLs: [URL], settings: CompressionSettings) -> URL? {
        let fallbackStem = AppState.defaultArchiveStem(for: sourceURLs)
        let archiveName = PathUtils.normalizedArchiveFileName(
            settings.archiveName,
            format: settings.format,
            fallbackStem: fallbackStem
        )

        if PathUtils.allShareParentDirectory(sourceURLs), let first = sourceURLs.first {
            let parent = first.deletingLastPathComponent()
            let proposed = parent.appendingPathComponent(archiveName)
            return PathUtils.uniqueFileURL(for: proposed)
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = archiveName
        panel.allowedContentTypes = [.archive, .data]
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    func resolveExtractDestinationURL(archiveURL: URL, chooseDestination: Bool) -> URL? {
        let folderName = PathUtils.splitArchiveName(archiveURL.lastPathComponent).stem
        let safeFolderName = folderName.isEmpty ? "Extracted" : folderName

        if chooseDestination {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Extract Here", bundle: .module)
            let response = panel.runModal()
            guard response == .OK, let chosenDir = panel.url else { return nil }
            let proposed = chosenDir.appendingPathComponent(safeFolderName)
            return PathUtils.uniqueFileURL(for: proposed)
        }

        let parent = archiveURL.deletingLastPathComponent()
        let proposed = parent.appendingPathComponent(safeFolderName)
        return PathUtils.uniqueFileURL(for: proposed)
    }

    nonisolated static func unwrapSingleTopDirectory(at url: URL) async {
        await Task.detached(priority: .userInitiated) {
            unwrapSingleTopDirectorySync(at: url)
        }.value
    }

    private nonisolated static func unwrapSingleTopDirectorySync(at url: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []),
              contents.count == 1 else { return }

        let wrapper = contents[0]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: wrapper.path, isDirectory: &isDir), isDir.boolValue else { return }

        // Rename wrapper first so a child with the exact same name as wrapper can still move cleanly.
        let stagingWrapper = url.appendingPathComponent(".bentozip_unwrap_\(UUID().uuidString)")
        do {
            try fm.moveItem(at: wrapper, to: stagingWrapper)
            let children = try fm.contentsOfDirectory(at: stagingWrapper, includingPropertiesForKeys: nil, options: [])
            for child in children {
                let target = url.appendingPathComponent(child.lastPathComponent)
                try fm.moveItem(at: child, to: target)
            }
            try fm.removeItem(at: stagingWrapper)
        } catch {
            // Best-effort rollback if staging failed halfway
            if fm.fileExists(atPath: stagingWrapper.path) && !fm.fileExists(atPath: wrapper.path) {
                try? fm.moveItem(at: stagingWrapper, to: wrapper)
            }
        }
    }
}
