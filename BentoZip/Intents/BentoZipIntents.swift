import AppIntents
import BentoZipCore
import Foundation
import UniformTypeIdentifiers

enum IntentArchiveFormat: String, AppEnum {
    case zip
    case sevenZip
    case tar
    case tarGz
    case tarBz2
    case tarXz
    case tarZstd
    case zstd
    case dmg
    case aar

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Archive Format")
    }

    static var caseDisplayRepresentations: [IntentArchiveFormat: DisplayRepresentation] {
        [
            .zip: "ZIP",
            .sevenZip: "7z",
            .tar: "TAR",
            .tarGz: "TAR.GZ",
            .tarBz2: "TAR.BZ2",
            .tarXz: "TAR.XZ",
            .tarZstd: "TAR.ZST",
            .zstd: "ZSTD",
            .dmg: "DMG",
            .aar: "Apple Archive",
        ]
    }

    var archiveFormat: ArchiveFormat {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tar: return .tar
        case .tarGz: return .tarGz
        case .tarBz2: return .tarBz2
        case .tarXz: return .tarXz
        case .tarZstd: return .tarZstd
        case .zstd: return .zstd
        case .dmg: return .dmg
        case .aar: return .aar
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Compress Files"
    static var description = IntentDescription(
        "Compress one or more files or folders into an archive using BentoZip."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Format", default: .zip)
    var format: IntentArchiveFormat

    @Parameter(title: "Password")
    var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard !files.isEmpty else {
            throw Bento7zError.operationFailed(
                String(localized: "No input files were provided."),
                "INVALID_PARAMS"
            )
        }

        let workDir = IntentFileSupport.makeTempDirectory(prefix: "BentoZipIntentCompress")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let inputStageDir = workDir.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputStageDir, withIntermediateDirectories: true)

        var sourceURLs: [URL] = []
        sourceURLs.reserveCapacity(files.count)
        for (index, item) in files.enumerated() {
            if let existingURL = item.fileURL, FileManager.default.fileExists(atPath: existingURL.path) {
                sourceURLs.append(existingURL)
            } else {
                let fallbackName = item.filename.isEmpty ? "item-\(index + 1)" : item.filename
                let dest = IntentFileSupport.uniqueURL(in: inputStageDir, preferredName: fallbackName)
                try item.data.write(to: dest)
                sourceURLs.append(dest)
            }
        }

        let targetFormat = format.archiveFormat
        let stem = AppState.defaultArchiveStem(for: sourceURLs)
        let outputName = "\(stem).\(targetFormat.fileExtension)"
        let outputURL = workDir.appendingPathComponent(outputName)

        let normalizedPassword: String? = (password?.isEmpty == false && targetFormat.supportsPassword) ? password : nil
        let settings = CompressionSettings(
            format: targetFormat,
            compressionLevel: .normal,
            archiveName: outputName,
            password: normalizedPassword
        )

        try await Bento7zEngine().create(
            from: sourceURLs,
            to: outputURL,
            settings: settings,
            onProgress: { _ in }
        )

        let archiveData = try Data(contentsOf: outputURL)
        let contentType = UTType(filenameExtension: targetFormat.fileExtension) ?? .archive
        let resultFile = IntentFile(data: archiveData, filename: outputName, type: contentType)
        return .result(value: resultFile)
    }
}

struct ExtractArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Archive"
    static var description = IntentDescription(
        "Extract the contents of an archive using BentoZip."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Destination Folder")
    var destination: IntentFile?

    @Parameter(title: "Password")
    var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let workDir = IntentFileSupport.makeTempDirectory(prefix: "BentoZipIntentExtract")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let archiveURL = try IntentFileSupport.materializeArchiveURL(from: archive, inside: workDir)
        let normalizedPassword: String? = (password?.isEmpty == false) ? password : nil

        let destinationDir: URL
        var createdDestinationInWorkDir = false
        if let destURL = destination?.fileURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir), isDir.boolValue {
                destinationDir = destURL
            } else {
                try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
                destinationDir = destURL
            }
        } else if let sourceFileURL = archive.fileURL, FileManager.default.fileExists(atPath: sourceFileURL.path) {
            let folderName = sourceFileURL.deletingPathExtension().lastPathComponent
            let candidate = sourceFileURL.deletingLastPathComponent().appendingPathComponent(
                folderName.isEmpty ? "Extracted" : folderName,
                isDirectory: true
            )
            let resolved = IntentFileSupport.uniqueDirectoryURL(preferred: candidate)
            try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
            destinationDir = resolved
        } else {
            let tempOut = workDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: tempOut, withIntermediateDirectories: true)
            destinationDir = tempOut
            createdDestinationInWorkDir = true
        }

        try await Bento7zEngine().extract(
            archiveURL: archiveURL,
            entries: nil,
            to: destinationDir,
            password: normalizedPassword,
            onProgress: { _ in }
        )

        let topItems = (try? FileManager.default.contentsOfDirectory(
            at: destinationDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let outputFiles: [IntentFile]
        if createdDestinationInWorkDir {
            var collected: [IntentFile] = []
            if let enumerator = FileManager.default.enumerator(
                at: destinationDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                while let url = enumerator.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    if values?.isRegularFile == true, let data = try? Data(contentsOf: url) {
                        let type = UTType(filenameExtension: url.pathExtension) ?? .data
                        collected.append(IntentFile(data: data, filename: url.lastPathComponent, type: type))
                    }
                }
            }
            outputFiles = collected
        } else {
            outputFiles = topItems.map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let type: UTType = (values?.isDirectory == true)
                    ? .folder
                    : (UTType(filenameExtension: url.pathExtension) ?? .data)
                return IntentFile(fileURL: url, filename: url.lastPathComponent, type: type)
            }
        }

        let summary = String(localized: "Extracted \(topItems.count) items to \(destinationDir.lastPathComponent).")
        return .result(value: outputFiles, dialog: IntentDialog("\(summary)"))
    }
}

struct ListArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "List Archive Contents"
    static var description = IntentDescription(
        "List all file and folder paths contained inside an archive."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let workDir = IntentFileSupport.makeTempDirectory(prefix: "BentoZipIntentList")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let archiveURL = try IntentFileSupport.materializeArchiveURL(from: archive, inside: workDir)
        let normalizedPassword: String? = (password?.isEmpty == false) ? password : nil

        let result = try await Bento7zEngine().listArchive(
            in: archiveURL,
            password: normalizedPassword
        )
        let paths = result.entries.map { $0.archiveRelativePath ?? $0.name }
        let summary = String(localized: "Found \(paths.count) entries in \(archiveURL.lastPathComponent).")
        return .result(value: paths, dialog: IntentDialog("\(summary)"))
    }
}

struct TestArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Verify Archive Integrity"
    static var description = IntentDescription(
        "Verify the integrity of an archive and report any corruption or errors."
    )

    @Parameter(title: "Archive")
    var archive: IntentFile

    @Parameter(title: "Password")
    var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let workDir = IntentFileSupport.makeTempDirectory(prefix: "BentoZipIntentTest")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let archiveURL = try IntentFileSupport.materializeArchiveURL(from: archive, inside: workDir)
        let normalizedPassword: String? = (password?.isEmpty == false) ? password : nil

        let result = try await Bento7zEngine().testArchive(
            at: archiveURL,
            password: normalizedPassword,
            onProgress: nil
        )

        let summary = String(
            localized: "\"\(archiveURL.lastPathComponent)\" passed integrity verification (\(result.itemsCount) items)."
        )
        return .result(value: summary, dialog: IntentDialog("\(summary)"))
    }
}

struct BentoZipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompressFilesIntent(),
            phrases: [
                "Compress files with \(.applicationName)",
                "Create archive with \(.applicationName)",
            ],
            shortTitle: "Compress Files",
            systemImageName: "archivebox"
        )
        AppShortcut(
            intent: ExtractArchiveIntent(),
            phrases: [
                "Extract archive with \(.applicationName)",
                "Unzip file with \(.applicationName)",
            ],
            shortTitle: "Extract Archive",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: ListArchiveIntent(),
            phrases: [
                "List archive contents with \(.applicationName)",
            ],
            shortTitle: "List Archive",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: TestArchiveIntent(),
            phrases: [
                "Verify archive with \(.applicationName)",
                "Test archive integrity with \(.applicationName)",
            ],
            shortTitle: "Verify Archive",
            systemImageName: "checkmark.shield"
        )
    }
}

private enum IntentFileSupport {
    static func makeTempDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func materializeArchiveURL(from file: IntentFile, inside tempDir: URL) throws -> URL {
        if let existingURL = file.fileURL, FileManager.default.fileExists(atPath: existingURL.path) {
            return existingURL
        }
        let filename = file.filename.isEmpty ? "archive.zip" : file.filename
        let targetURL = tempDir.appendingPathComponent(filename)
        try file.data.write(to: targetURL)
        return targetURL
    }

    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let stem = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let next = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: next.path) {
                return next
            }
            index += 1
        }
    }

    static func uniqueDirectoryURL(preferred: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: preferred.path) {
            return preferred
        }
        let parent = preferred.deletingLastPathComponent()
        let baseName = preferred.lastPathComponent
        var index = 2
        while true {
            let candidate = parent.appendingPathComponent("\(baseName) \(index)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
