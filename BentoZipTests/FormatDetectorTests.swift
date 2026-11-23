import Foundation
import Testing
import BentoZipCore

@Suite(.serialized)
struct FormatDetectorTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("FormatDetectorTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Compound & Single Extensions

    @Test func detectFormat_writableExtensions() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.zip")) == .zip)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.7z")) == .sevenZip)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tar")) == .tar)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tar.gz")) == .tarGz)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tgz")) == .tarGz)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tar.bz2")) == .tarBz2)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tbz2")) == .tarBz2)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tbz")) == .tarBz2)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tar.xz")) == .tarXz)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.txz")) == .tarXz)
        // Single-stream compressed formats are read-only so mutating never corrupts them into tar
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.gz")) == nil)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.xz")) == nil)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.bz2")) == nil)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "readme.txt")) == nil)
    }

    @Test func detectReadableFormat_compoundAndReadOnlyExtensions() {
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tar.gz")) == .tarGz)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tgz")) == .tarGz)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tar.bz2")) == .tarBz2)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tbz2")) == .tarBz2)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tbz")) == .tarBz2)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.tar.xz")) == .tarXz)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.txz")) == .tarXz)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.gz")) == .gz)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.rar")) == .rar)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "a.rar"))?.isReadOnly == true)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "a.rar")) == nil)
        #expect(FormatDetector.isArchiveFile(URL(fileURLWithPath: "a.rar")))
    }

    @Test func detectFormat_ignoresDirectoriesNamedLikeArchives() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let folderNamedZip = dir.appendingPathComponent("folder.zip")
        try fm.createDirectory(at: folderNamedZip, withIntermediateDirectories: true)

        #expect(FormatDetector.detectReadableFormat(of: folderNamedZip) == nil)
        #expect(!FormatDetector.isArchiveFile(folderNamedZip))
    }

    // MARK: - Magic Bytes

    @Test func detectReadableFormat_magicBytes() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let cases: [(String, [UInt8], ReadableArchiveFormat)] = [
            ("zip.bin", [0x50, 0x4B, 0x03, 0x04], .zip),
            ("empty_zip.bin", [0x50, 0x4B, 0x05, 0x06], .zip),
            ("sevenz.bin", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], .sevenZip),
            ("rar.bin", [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], .rar),
            ("xz.bin", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], .xz),
            ("bz2.bin", [0x42, 0x5A, 0x68, 0x39], .bz2),
            ("gz.bin", [0x1F, 0x8B, 0x08, 0x00], .gz),
        ]

        for (name, bytes, expected) in cases {
            let file = dir.appendingPathComponent(name)
            try Data(bytes).write(to: file)
            #expect(FormatDetector.detectReadableFormat(of: file) == expected)
        }
    }

    @Test func detectReadableFormat_tarUstarMagicAtOffset257() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        var bytes = [UInt8](repeating: 0, count: 512)
        let ustar = Array("ustar".utf8)
        bytes.replaceSubrange(257..<262, with: ustar)

        let tarFile = dir.appendingPathComponent("archive.bin")
        try Data(bytes).write(to: tarFile)

        #expect(FormatDetector.detectReadableFormat(of: tarFile) == .tar)
        #expect(FormatDetector.detectFormat(of: tarFile) == .tar)
    }

    @Test func detectReadableFormat_emptyAndUnknownFiles() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let emptyFile = dir.appendingPathComponent("empty.bin")
        try Data().write(to: emptyFile)
        #expect(FormatDetector.detectReadableFormat(of: emptyFile) == nil)

        let textFile = dir.appendingPathComponent("plain.dat")
        try Data("hello world".utf8).write(to: textFile)
        #expect(FormatDetector.detectReadableFormat(of: textFile) == nil)
    }

    @Test func detectReadableFormat_extensionTakesPrecedenceOverMagic() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("test.zip")
        try Data([0x1F, 0x8B, 0x08]).write(to: file)

        #expect(FormatDetector.detectFormat(of: file) == .zip)
    }
}

@Suite(.serialized)
struct ArchiveTreeBuilderTests {
    @Test func build_createsIntermediateDirectoriesAndPreservesMetadata() {
        let modDate = Date(timeIntervalSince1970: 1_700_000_000)
        let flat: [ArchiveTreeBuilder.FlatEntry] = [
            .init(
                path: "docs/guide/intro.md",
                name: "intro.md",
                isDirectory: false,
                size: 1024,
                packedSize: 512,
                modificationDate: modDate,
                isEncrypted: true
            ),
            .init(
                path: "README.txt",
                name: "README.txt",
                isDirectory: false,
                size: 200,
                packedSize: 120,
                modificationDate: nil,
                isEncrypted: false
            )
        ]

        let tree = ArchiveTreeBuilder.build(from: flat)
        #expect(tree.count == 2)

        // Directories sort before files
        let docs = tree[0]
        #expect(docs.name == "docs")
        #expect(docs.isDirectory)

        let guide = docs.children?.first
        #expect(guide?.name == "guide")
        #expect(guide?.isDirectory == true)

        let intro = guide?.children?.first
        #expect(intro?.name == "intro.md")
        #expect(intro?.size == 1024)
        #expect(intro?.packedSize == 512)
        #expect(intro?.isEncrypted == true)
        #expect(intro?.modificationDate == modDate)
        #expect(intro?.archiveRelativePath == "docs/guide/intro.md")
    }

    @Test func build_unwrapsSingleTopDirectoryAndKeepsArchiveRelativePath() {
        let flat: [ArchiveTreeBuilder.FlatEntry] = [
            .init(path: "Wrapper/a.txt", name: "a.txt", isDirectory: false, size: 10),
            .init(path: "Wrapper/b.txt", name: "b.txt", isDirectory: false, size: 20)
        ]

        let tree = ArchiveTreeBuilder.build(from: flat)
        #expect(tree.count == 2)
        #expect(tree.map(\.name) == ["a.txt", "b.txt"])
        #expect(tree.first?.archiveRelativePath == "Wrapper/a.txt")
    }

    @Test func build_normalizesLeadingDotSlashInTarPaths() {
        let flat: [ArchiveTreeBuilder.FlatEntry] = [
            .init(path: "./alpha.txt", name: "alpha.txt", isDirectory: false, size: 42),
            .init(path: "./sub/beta.txt", name: "beta.txt", isDirectory: false, size: 84)
        ]

        let tree = ArchiveTreeBuilder.build(from: flat)
        #expect(tree.count == 2)
        #expect(tree[0].name == "sub")
        #expect(tree[1].name == "alpha.txt")
        #expect(tree[1].archiveRelativePath == "./alpha.txt")
    }

    @Test func build_rejectsPathTraversalAndAbsolutePaths() {
        let flat: [ArchiveTreeBuilder.FlatEntry] = [
            .init(path: "../outside.txt", name: "outside.txt", isDirectory: false, size: 10),
            .init(path: "sub/../../escape.txt", name: "escape.txt", isDirectory: false, size: 10),
            .init(path: "..\\win_escape.txt", name: "win_escape.txt", isDirectory: false, size: 10),
            .init(path: "/etc/passwd", name: "passwd", isDirectory: false, size: 10),
            .init(path: "\\Windows\\System32\\cmd.exe", name: "cmd.exe", isDirectory: false, size: 10),
            .init(path: "C:/evil.txt", name: "evil.txt", isDirectory: false, size: 10),
            .init(path: "safe/file.txt", name: "../spoof", isDirectory: false, size: 42),
            .init(path: "safe\\nested.txt", name: "nested.txt", isDirectory: false, size: 24)
        ]

        let tree = ArchiveTreeBuilder.build(from: flat)
        // Single "safe" directory is unwrapped to its children
        #expect(tree.count == 2)
        let names = Set(tree.map(\.name))
        #expect(names == ["file.txt", "nested.txt"])
        for entry in tree {
            #expect(entry.url.standardizedFileURL.path.hasPrefix("/archive-root/"))
        }
    }
}
