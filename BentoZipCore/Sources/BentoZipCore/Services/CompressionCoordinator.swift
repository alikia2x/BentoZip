import SwiftUI
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
public class CompressionCoordinator {
    private let zipEngine = ZIPEngine()
    private let archiveReader = LibArchiveReader()
    private let archiveWriter = LibArchiveWriter()

    public init() {}

    public func engine(for format: ArchiveFormat) -> ArchiveEngine {
        switch format {
        case .zip: return zipEngine
        case .sevenZip, .tarGz: return archiveWriter
        }
    }

    public func readerEngine() -> some ArchiveEngine {
        return archiveReader
    }

    public func zipEngineRef() -> ZIPEngine {
        return zipEngine
    }

    private func unwrapSingleTopDirectory(at url: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []),
              contents.count == 1 else { return }
        let wrapper = contents[0]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: wrapper.path, isDirectory: &isDir), isDir.boolValue else { return }

        guard let children = try? fm.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil, options: []) else { return }
        for child in children {
            let newURL = url.appendingPathComponent(child.lastPathComponent)
            try? fm.moveItem(at: child, to: newURL)
        }
        try? fm.removeItem(at: wrapper)
    }

    public func browseArchive(at url: URL, appState: AppState) async {
        appState.mode = .browseArchive
        appState.sourceArchiveURL = url

        do {
            let format = FormatDetector.detectFormat(of: url) ?? .zip
            let engine = format == .zip ? (archiveReader as ArchiveEngine) : archiveReader
            let entries = try await engine.listEntries(in: url)
            appState.fileEntries = entries
        } catch {
            appState.lastError = "无法读取压缩包: \(error.localizedDescription)"
            appState.reset()
        }
    }

    public func compress(appState: AppState, progressState: ProgressState, openWindow: OpenWindowAction) async {
        guard appState.mode == .compress, !appState.fileEntries.isEmpty else { return }

        let settings = appState.compressionSettings
        let sourceURLs = appState.fileEntries.map { $0.url }

        let saveURL: URL
        let archiveName = settings.archiveName.isEmpty
            ? "archive.\(settings.format.fileExtension)"
            : settings.archiveName

        if PathUtils.allShareParentDirectory(sourceURLs) {
            let parent = sourceURLs.first!.deletingLastPathComponent()
            let proposed = parent.appendingPathComponent(archiveName)
            saveURL = PathUtils.uniqueFileURL(for: proposed)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = archiveName
            panel.allowedContentTypes = [.archive, .data]
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            saveURL = url
        }

        progressState.isOperationInProgress = true
        progressState.operationProgress = 0.0
        progressState.operationDescription = "正在压缩..."
        openWindow(id: "progress")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }

        do {
            let engine = engine(for: settings.format)
            try await engine.create(
                from: sourceURLs,
                to: saveURL,
                settings: settings,
                progress: { progressState.operationProgress = $0 }
            )

            progressState.operationProgress = 1.0
            progressState.isOperationInProgress = false
            appState.lastError = nil

            try? await Task.sleep(for: .milliseconds(500))
            progressState.shouldDismiss = true

            await browseArchive(at: saveURL, appState: appState)
        } catch {
            progressState.isOperationInProgress = false
            progressState.shouldDismiss = true
            appState.lastError = "压缩失败: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: saveURL)
        }
    }

    public func extract(appState: AppState, progressState: ProgressState, openWindow: OpenWindowAction) async {
        guard appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL else { return }

        let destinationURL: URL
        if PathUtils.allShareParentDirectory([archiveURL]) {
            let parent = archiveURL.deletingLastPathComponent()
            let folderName = archiveURL.deletingPathExtension().lastPathComponent
            destinationURL = parent.appendingPathComponent(folderName)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "选择解压位置"
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            destinationURL = url
        }

        progressState.isOperationInProgress = true
        progressState.operationProgress = 0.0
        progressState.operationDescription = "正在解压..."
        openWindow(id: "progress")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }

        do {
            let format = FormatDetector.detectFormat(of: archiveURL) ?? .zip
            let engine = format == .zip ? (archiveReader as ArchiveEngine) : archiveReader
            try await engine.extract(
                archiveURL: archiveURL,
                entries: nil,
                to: destinationURL,
                progress: { progressState.operationProgress = $0 }
            )

            progressState.operationProgress = 1.0
            progressState.isOperationInProgress = false
            appState.lastError = nil

            unwrapSingleTopDirectory(at: destinationURL)

            try? await Task.sleep(for: .milliseconds(500))
            progressState.shouldDismiss = true

            NSWorkspace.shared.open(destinationURL)
        } catch {
            progressState.isOperationInProgress = false
            progressState.shouldDismiss = true
            appState.lastError = "解压失败: \(error.localizedDescription)"
        }
    }
}
