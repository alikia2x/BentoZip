import Foundation

/// Helpers for lightweight inline file previewing and image/comic gallery filtering.
public enum InlinePreviewHelper: Sendable {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
        "tiff", "tif", "bmp", "ico", "svg", "avif", "jxl",
        "jp2", "psd", "raw", "cr2", "nef", "arw", "dng"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "rtf", "csv", "tsv", "log",
        "json", "jsonc", "jsonl", "yaml", "yml", "toml", "xml", "plist",
        "ini", "cfg", "conf", "env", "properties",
        "html", "htm", "css", "scss", "sass", "less",
        "js", "jsx", "mjs", "cjs", "ts", "tsx",
        "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm",
        "rs", "go", "py", "rb", "php", "java", "kt", "kts", "scala", "cs",
        "sh", "bash", "zsh", "fish", "bat", "cmd", "ps1",
        "sql", "graphql", "gql",
        "dockerfile", "makefile", "cmake", "gradle",
        "lua", "pl", "pm", "r", "dart", "ex", "exs", "erl", "hs", "clj", "lisp", "vim",
        "tex", "bib", "diff", "patch",
        "gitignore", "gitattributes", "editorconfig", "lock",
        "pbxproj", "xcconfig", "strings", "xcstrings"
    ]

    private static let textBaseNames: Set<String> = [
        "readme", "license", "licence", "changelog", "changes", "authors", "contributing",
        "makefile", "dockerfile", "gemfile", "podfile", "procfile", "vagrantfile",
        "brewfile", "rakefile", "cmakelists.txt", ".gitignore", ".gitattributes",
        ".editorconfig", ".env", ".zshrc", ".bashrc", ".profile"
    ]

    /// Return `true` if `fileName` has a recognized image extension.
    public static func isImageFile(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return !ext.isEmpty && imageExtensions.contains(ext)
    }

    /// Return `true` if `url` has a recognized image extension.
    public static func isImageFile(_ url: URL) -> Bool {
        isImageFile(url.lastPathComponent)
    }

    /// Return `true` if `fileName` represents a plain-text, markup, config, or source code file.
    public static func isTextPreviewable(_ fileName: String) -> Bool {
        let baseName = (fileName as NSString).lastPathComponent.lowercased()
        if textBaseNames.contains(baseName) {
            return true
        }
        let ext = (baseName as NSString).pathExtension
        return !ext.isEmpty && textExtensions.contains(ext)
    }

    /// Return `true` if `url` represents a plain-text, markup, config, or source code file.
    public static func isTextPreviewable(_ url: URL) -> Bool {
        isTextPreviewable(url.lastPathComponent)
    }

    /// Asynchronously read up to `maxBytes` of UTF-8/UTF-16/Latin-1 text from `url` off the main actor.
    /// Returns `nil` if the file cannot be read or appears to contain binary NUL bytes.
    public static func loadTextSnippet(from url: URL, maxBytes: Int = 65_536) async -> String? {
        guard maxBytes > 0 else { return "" }
        return await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
            if data.isEmpty { return "" }

            // Check UTF-16 BOM before NUL-byte rejection.
            if data.count >= 2 {
                let b0 = data[data.startIndex]
                let b1 = data[data.index(after: data.startIndex)]
                if (b0 == 0xFE && b1 == 0xFF) || (b0 == 0xFF && b1 == 0xFE) {
                    return String(data: data, encoding: .utf16)
                }
            }

            // Reject binary data containing NUL bytes.
            if data.contains(0x00) {
                return nil
            }

            if let utf8 = String(data: data, encoding: .utf8) {
                return utf8
            }

            // If we truncated mid-character at `maxBytes`, trim up to 3 trailing continuation bytes.
            for trim in 1...min(3, data.count) {
                let sliced = data.dropLast(trim)
                if let utf8 = String(data: sliced, encoding: .utf8) {
                    return utf8
                }
            }

            return String(data: data, encoding: .isoLatin1)
        }.value
    }
}
