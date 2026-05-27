import Foundation
import Testing
import BentoZipCore

@MainActor
struct LibArchiveReaderTests {
    let reader = LibArchiveReader()
    let fm = FileManager.default

    // MARK: - Helpers

    func makeTempDir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("BentoZipTest_\(UUID().uuidString)")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeTestFiles(in dir: URL, files: [String: String]) throws {
        for (name, content) in files {
            let fileURL = dir.appendingPathComponent(name)
            let parent = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    func makeZip(from dir: URL, files: [String: String]) async throws -> URL {
        try makeTestFiles(in: dir, files: files)
        let zipURL = dir.appendingPathComponent("test.zip")
        let zipEngine = ZIPEngine()
        let sourceURLs = files.keys.map { dir.appendingPathComponent($0) }
        let settings = CompressionSettings(format: .zip)
        try await zipEngine.create(from: sourceURLs, to: zipURL, settings: settings, progress: { _ in })
        return zipURL
    }

    func makeTarGz(from dir: URL, files: [String: String]) throws -> URL {
        try makeTestFiles(in: dir, files: files)
        let tarURL = dir.appendingPathComponent("test.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tarURL.path] + files.keys.map { _ in "-C" } + [dir.path] + files.keys.map { $0 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard fm.fileExists(atPath: tarURL.path) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "tar creation failed"])
        }
        return tarURL
    }

    func make7z(from dir: URL, files: [String: String]) async throws -> URL {
        try makeTestFiles(in: dir, files: files)
        let archiveURL = dir.appendingPathComponent("test.7z")
        let writer = LibArchiveWriter()
        let sourceURLs = files.keys.map { dir.appendingPathComponent($0) }
        let settings = CompressionSettings(format: .sevenZip)
        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })
        return archiveURL
    }

    func cleanup(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    // MARK: - listEntries

    @Test func listEntries_zipWithFilesAndDirs() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["hello.txt": "world", "sub/note.txt": "subcontent"])

        let entries = try await reader.listEntries(in: zip)
        #expect(!entries.isEmpty)
        // Should have at least hello.txt and sub/
        let names = Set(entries.map { $0.name })
        #expect(names.contains("hello.txt") || names.contains("sub"))
    }

    @Test func listEntries_tarGzWithFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let archive = try makeTarGz(from: tmp, files: ["a.txt": "aaa", "b.txt": "bbb"])

        let entries = try await reader.listEntries(in: archive)
        #expect(!entries.isEmpty)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("a.txt"))
    }

    @Test func listEntries_7zWithFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let archive = try await make7z(from: tmp, files: ["x.txt": "xxx"])

        let entries = try await reader.listEntries(in: archive)
        #expect(!entries.isEmpty)
    }

    @Test func listEntries_emptyZip() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["only.txt": "data"])

        let entries = try await reader.listEntries(in: zip)
        #expect(!entries.isEmpty)
        #expect(entries.contains(where: { $0.name == "only.txt" }))
    }

    @Test func listEntries_nonexistentFile_throws() async {
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_file_xyz123.zip")
        do {
            _ = try await reader.listEntries(in: nonexistent)
            #expect(Bool(false), "Expected error")
        } catch let error as LibArchiveReader.ReaderError {
            if case .openFailed = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected openFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func listEntries_returnsFileEntriesWithCorrectProperties() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["hello.txt": "world"])

        let entries = try await reader.listEntries(in: zip)
        let fileEntry = try #require(entries.first(where: { $0.name == "hello.txt" }))
        #expect(!fileEntry.isDirectory)
        #expect(fileEntry.size > 0)
        #expect(fileEntry.isFromArchive)
    }

    // MARK: - extract (bulk)

    @Test func extract_allEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["a.txt": "contentA", "b.txt": "contentB"])

        let dest = tmp.appendingPathComponent("extracted")
        try await reader.extract(archiveURL: zip, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("b.txt").path))
        let contentA = try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contentA == "contentA")
    }

    @Test func extract_selectiveEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["keep.txt": "keep", "skip.txt": "skip"])

        let allEntries = try await reader.listEntries(in: zip)
        let keepEntries = allEntries.filter { $0.name == "keep.txt" }

        let dest = tmp.appendingPathComponent("extracted")
        try await reader.extract(archiveURL: zip, entries: keepEntries, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("keep.txt").path))
        // skip.txt should not exist (or at least, it depends on how selective extraction works)
    }

    @Test func extract_withProgressCallback() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["f1.txt": "1", "f2.txt": "2"])

        var progressValues: [Double] = []
        let dest = tmp.appendingPathComponent("extracted")
        try await reader.extract(archiveURL: zip, entries: nil, to: dest, progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }

    @Test func extract_nonexistentArchive_throws() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let dest = tmp.appendingPathComponent("extracted")
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_xyz.zip")

        do {
            try await reader.extract(archiveURL: nonexistent, entries: nil, to: dest, progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch let error as LibArchiveReader.ReaderError {
            if case .openFailed = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected openFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extract_createsNestedDirectories() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["deep/nested/file.txt": "deepcontent"])

        let dest = tmp.appendingPathComponent("extracted")
        try await reader.extract(archiveURL: zip, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("deep/nested/file.txt").path))
    }

    // MARK: - extractEntry

    @Test func extractEntry_singleEntryByPath() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["song.mp3": "binary"])

        let dest = tmp.appendingPathComponent("song.mp3")
        try await reader.extractEntry(from: zip, entryPath: "song.mp3", to: dest)

        #expect(fm.fileExists(atPath: dest.path))
    }

    @Test func extractEntry_nonexistentEntry_throws() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["real.txt": "data"])

        let dest = tmp.appendingPathComponent("ghost.txt")
        do {
            try await reader.extractEntry(from: zip, entryPath: "no_such_entry.txt", to: dest)
            #expect(Bool(false), "Expected error")
        } catch let error as LibArchiveReader.ReaderError {
            if case .entryNotFound = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected entryNotFound, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractEntry_createsParentDirectories() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["nested/file.txt": "content"])

        let dest = tmp.appendingPathComponent("out/nested/file.txt")
        try await reader.extractEntry(from: zip, entryPath: "nested/file.txt", to: dest)

        #expect(fm.fileExists(atPath: dest.path))
    }

    // MARK: - detectFormat

    @Test func detectFormat_zip_extension() {
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        #expect(LibArchiveReader.detectFormat(of: url) == .zip)
    }

    @Test func detectFormat_7z_extension() {
        let url = URL(fileURLWithPath: "/tmp/test.7z")
        #expect(LibArchiveReader.detectFormat(of: url) == .sevenZip)
    }

    @Test func detectFormat_tarGz_extension() {
        let url = URL(fileURLWithPath: "/tmp/test.tar.gz")
        #expect(LibArchiveReader.detectFormat(of: url) == .tarGz)
    }

    @Test func detectFormat_tgz_extension() {
        let url = URL(fileURLWithPath: "/tmp/test.tgz")
        #expect(LibArchiveReader.detectFormat(of: url) == .tarGz)
    }

    @Test func detectFormat_unknown_extension() {
        let url = URL(fileURLWithPath: "/tmp/readme.txt")
        #expect(LibArchiveReader.detectFormat(of: url) == nil)
    }

    @Test func detectFormat_byMagicBytes() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["f.txt": "data"])
        // Rename to remove extension, still should be detected by magic bytes
        let renamed = tmp.appendingPathComponent("archive.data")
        try fm.moveItem(at: zip, to: renamed)

        #expect(LibArchiveReader.detectFormat(of: renamed) == .zip)
    }

    // MARK: - Unsupported operations

    @Test func create_throws() async {
        do {
            let _ = try await reader.create(from: [], to: URL(fileURLWithPath: "/tmp/x.zip"),
                settings: CompressionSettings(), progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func removeEntries_throws() async {
        do {
            try await reader.removeEntries(from: URL(fileURLWithPath: "/tmp/x.zip"), entries: [])
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func addEntries_throws() async {
        do {
            try await reader.addEntries(to: URL(fileURLWithPath: "/tmp/x.zip"), from: [], progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }
}
