import AppKit
import BentoZipCore
import Foundation
import UniformTypeIdentifiers

@MainActor
enum FileKindCache {
    private static var cache: [String: String] = [:]

    static func localizedKind(for entry: FileEntry) -> String {
        if entry.isDirectory {
            return String(localized: "Folder")
        }
        let ext = entry.url.pathExtension.lowercased()
        if ext.isEmpty {
            return String(localized: "Document")
        }
        if let cached = cache[ext] {
            return cached
        }
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        cache[ext] = kind
        return kind
    }
}

extension FileEntry {
    var sortableSize: Int64 {
        isDirectory ? -1 : size
    }

    var sortablePackedSize: Int64 {
        packedSize ?? -1
    }

    var sortableModificationDate: Date {
        modificationDate ?? .distantPast
    }
}

enum FileListTreeSupport {
    static func sorted(_ base: [FileEntry], using sortOrder: [KeyPathComparator<FileEntry>]) -> [FileEntry] {
        if let firstComparator = sortOrder.first, firstComparator.keyPath == \FileEntry.name {
            let folders = base.filter(\.isDirectory).sorted(using: sortOrder)
            let files = base.filter { !$0.isDirectory }.sorted(using: sortOrder)
            return folders + files
        }
        return base.sorted(using: sortOrder)
    }

    static func findEntries(matching ids: Set<UUID>, in list: [FileEntry]) -> [FileEntry] {
        var result: [FileEntry] = []
        for entry in list {
            if ids.contains(entry.id) {
                result.append(entry)
            }
            if let children = entry.children, !children.isEmpty {
                result.append(contentsOf: findEntries(matching: ids, in: children))
            }
        }
        return result
    }

    @MainActor
    static func handleExtractionError(_ error: Error, appState: AppState) {
        if let bentoError = error as? Bento7zError,
           bentoError == .passwordRequired || bentoError == .wrongPassword {
            if bentoError == .wrongPassword {
                appState.archivePassword = nil
            }
            appState.pendingPasswordArchiveURL = appState.sourceArchiveURL
            appState.isPasswordRetryError = (bentoError == .wrongPassword)
            appState.passwordPromptReason = bentoError.localizedDescription
            appState.needsPasswordPrompt = true
        } else {
            appState.lastError = error.localizedDescription
        }
    }

    @MainActor
    static func makeItemProvider(for entry: FileEntry, appState: AppState) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name

        let sourceArchiveURL = appState.sourceArchiveURL
        let password = appState.archivePassword

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.item.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                do {
                    let localURL = try await DragDropManager.shared.prepareForDragThrowing(
                        entry,
                        sourceArchiveURL: sourceArchiveURL,
                        password: password
                    )
                    completion(localURL, false, nil)
                } catch {
                    handleExtractionError(error, appState: appState)
                    completion(nil, false, error)
                }
            }
            return nil
        }

        return provider
    }
}
