import SwiftUI
import UniformTypeIdentifiers
import Observation

@Observable
@MainActor
public class CompressionCoordinator {
    private let engine = Bento7zEngine()

    public init() {}

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
            let entries = try await engine.listEntries(in: url)
            appState.fileEntries = entries
        } catch {
            appState.reset()
            appState.lastError = "无法读取压缩包: \(error.localizedDescription)"
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
            try await engine.create(
                from: sourceURLs,
                to: saveURL,
                settings: settings,
                progress: { progressState.operationProgress = $0 }
            )

            progressState.operationProgress = 1.0
            progressState.isOperationInProgress = false
            appState.lastError = nil

            try? await Task.sleep(for: .milliseconds(300))
            progressState.shouldDismiss = true

            NSWorkspace.shared.activateFileViewerSelecting([saveURL])
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
        let parent = archiveURL.deletingLastPathComponent()
        let folderName = archiveURL.deletingPathExtension().lastPathComponent
        destinationURL = parent.appendingPathComponent(folderName)

        progressState.isOperationInProgress = true
        progressState.operationProgress = 0.0
        progressState.operationDescription = "正在解压..."
        openWindow(id: "progress")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }

        do {
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

            try? await Task.sleep(for: .milliseconds(300))
            progressState.shouldDismiss = true

            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            progressState.isOperationInProgress = false
            progressState.shouldDismiss = true
            appState.lastError = "解压失败: \(error.localizedDescription)"
        }
    }
    
    public func addEntries(appState: AppState, urls: [URL], progressState: ProgressState, openWindow: OpenWindowAction) async {
        guard appState.mode == .browseArchive, let archiveURL = appState.sourceArchiveURL else { return }

        progressState.isOperationInProgress = true
        progressState.operationProgress = 0.0
        progressState.operationDescription = "正在添加..."
        openWindow(id: "progress")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
        }

        do {
            try await engine.addEntries(to: archiveURL, from: urls, progress:  { progressState.operationProgress = $0 })
            
            progressState.operationProgress = 1.0
            progressState.isOperationInProgress = false
            appState.lastError = nil


            try? await Task.sleep(for: .milliseconds(250))
            progressState.shouldDismiss = true

        } catch {
            progressState.isOperationInProgress = false
            progressState.shouldDismiss = true
            appState.lastError = "添加失败: \(error.localizedDescription)"
        }
    }
}
