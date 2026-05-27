import Foundation

enum PathUtils {
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
        let commonPath = first.prefix(commonCount).joined(separator: "/")
        return URL(fileURLWithPath: "/" + commonPath)
    }

    /// Check if all URLs share the same immediate parent directory.
    static func allShareParentDirectory(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let parents = urls.map { $0.deletingLastPathComponent().standardized }
        guard let first = parents.first else { return false }
        return parents.allSatisfy { $0 == first }
    }

    /// Generate a unique file URL by appending a number if the file already exists.
    static func uniqueFileURL(for proposedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }
        let directory = proposedURL.deletingLastPathComponent()
        let stem = proposedURL.deletingPathExtension().lastPathComponent
        let ext = proposedURL.pathExtension
        var counter = 2
        var url: URL
        repeat {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            url = directory.appendingPathComponent(name)
            counter += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    /// Get the file extension for a given archive format.
    static func fileExtension(for format: ArchiveFormat) -> String {
        return format.fileExtension
    }
}
