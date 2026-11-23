import Foundation

enum PathUtils {
    private static let compoundArchiveExtensions = [
        "tar.gz", "tar.bz2", "tar.xz"
    ]

    /// Compute the common parent directory of a set of URLs.
    static func commonParentDirectory(of urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let paths = urls.map { $0.standardized.pathComponents }
        guard let first = paths.first else { return nil }
        var commonCount = 0
        for i in 0..<first.count {
            let component = first[i]
            if !paths.allSatisfy({ $0.count > i && $0[i] == component }) {
                break
            }
            commonCount += 1
        }
        guard commonCount > 0 else { return nil }
        let components = Array(first.prefix(commonCount))
        if components == ["/"] {
            return URL(fileURLWithPath: "/")
        }
        let trimmed = components.first == "/" ? Array(components.dropFirst()) : components
        return URL(fileURLWithPath: "/" + trimmed.joined(separator: "/"))
    }

    /// Check if all URLs share the same immediate parent directory.
    static func allShareParentDirectory(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let parents = urls.map { $0.deletingLastPathComponent().standardized }
        guard let first = parents.first else { return false }
        return parents.allSatisfy { $0 == first }
    }

    /// Split a filename into stem and extension, recognizing compound archive extensions such as `.tar.gz`.
    static func splitArchiveName(_ fileName: String) -> (stem: String, ext: String) {
        let lowercased = fileName.lowercased()
        for compound in compoundArchiveExtensions {
            let suffix = "." + compound
            if lowercased.hasSuffix(suffix) && fileName.count > suffix.count {
                let stemEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
                let stem = String(fileName[..<stemEnd])
                let extStart = fileName.index(after: stemEnd)
                let ext = String(fileName[extStart...])
                return (stem, ext)
            }
        }

        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? fileName : url.deletingPathExtension().lastPathComponent
        return (stem, ext)
    }

    /// Generate a unique file URL by appending a counter when the target already exists.
    static func uniqueFileURL(for proposedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }
        let directory = proposedURL.deletingLastPathComponent()
        let (stem, ext) = splitArchiveName(proposedURL.lastPathComponent)
        var counter = 2
        var url: URL
        repeat {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            url = directory.appendingPathComponent(name)
            counter += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    /// Sanitize a user-supplied archive filename and ensure it includes the format extension.
    static func normalizedArchiveFileName(
        _ rawName: String,
        format: ArchiveFormat,
        fallbackStem: String = "archive"
    ) -> String {
        let stripped = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let safeFallbackStem = fallbackStem.isEmpty ? "archive" : fallbackStem
        guard !stripped.isEmpty, stripped != ".", stripped != ".." else {
            return "\(safeFallbackStem).\(format.fileExtension)"
        }

        let requiredSuffix = ".\(format.fileExtension)"
        if stripped.lowercased().hasSuffix(requiredSuffix.lowercased()) {
            return stripped
        }
        return stripped + requiredSuffix
    }

    /// Get the file extension for a given archive format.
    static func fileExtension(for format: ArchiveFormat) -> String {
        format.fileExtension
    }
}
