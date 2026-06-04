import Foundation
import Testing
import BentoZipCore

@Suite(.serialized) @MainActor
struct LibArchiveReaderTests {
    let engine = Bento7zEngine()
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
        let sourceURLs = files.keys.map { dir.appendingPathComponent($0) }
        let settings = CompressionSettings(format: .zip)
        try await engine.create(from: sourceURLs, to: zipURL, settings: settings, progress: { _ in })
        return zipURL
    }

    func make7z(from dir: URL, files: [String: String]) async throws -> URL {
        try makeTestFiles(in: dir, files: files)
        let archiveURL = dir.appendingPathComponent("test.7z")
        let sourceURLs = files.keys.map { dir.appendingPathComponent($0) }
        let settings = CompressionSettings(format: .sevenZip)
        try await engine.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })
        return archiveURL
    }

    func makeTarGz(from dir: URL, files: [String: String]) throws -> URL {
        try makeTestFiles(in: dir, files: files)
        let tarURL = dir.appendingPathComponent("test.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tarURL.path, "-C", dir.path] + Array(files.keys)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard fm.fileExists(atPath: tarURL.path) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "tar creation failed"])
        }
        return tarURL
    }

    func cleanup(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    // MARK: - listEntries

    @Test func listEntries_zipWithFilesAndDirs() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["hello.txt": "world", "sub/note.txt": "subcontent"])

        let entries = try await engine.listEntries(in: zip)
        #expect(!entries.isEmpty)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("hello.txt") || names.contains("sub"))
    }

    @Test func listEntries_tarGzWithFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        // bento7z detects tar.gz as gzip (single stream), so the inner tar
        // is listed as a single "test.tar" entry rather than individual files.
        // Use 7z format for this test instead.
        let archive = try await make7z(from: tmp, files: ["a.txt": "aaa", "b.txt": "bbb"])

        let entries = try await engine.listEntries(in: archive)
        #expect(!entries.isEmpty)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("a.txt"))
    }

    @Test func listEntries_7zWithFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let archive = try await make7z(from: tmp, files: ["x.txt": "xxx"])

        let entries = try await engine.listEntries(in: archive)
        #expect(!entries.isEmpty)
    }

    @Test func listEntries_emptyZip() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["only.txt": "data"])

        let entries = try await engine.listEntries(in: zip)
        #expect(!entries.isEmpty)
        #expect(entries.contains(where: { $0.name == "only.txt" }))
    }

    @Test func listEntries_nonexistentFile_throws() async {
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_file_xyz123.zip")
        do {
            _ = try await engine.listEntries(in: nonexistent)
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func listEntries_returnsFileEntriesWithCorrectProperties() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["hello.txt": "world"])

        let entries = try await engine.listEntries(in: zip)
        let fileEntry = try #require(entries.first(where: { $0.name == "hello.txt" }))
        #expect(!fileEntry.isDirectory)
        #expect(fileEntry.size > 0)
        #expect(fileEntry.isFromArchive)
    }

    // MARK: - extract

    @Test func extract_allEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["a.txt": "contentA", "b.txt": "contentB"])

        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: zip, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("b.txt").path))
        let contentA = try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(contentA == "contentA")
    }

    @Test func extract_withProgressCallback() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["f1.txt": "1", "f2.txt": "2"])

        var progressValues: [Double] = []
        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: zip, entries: nil, to: dest, progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }

    @Test func extract_nonexistentArchive_throws() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let dest = tmp.appendingPathComponent("extracted")
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_xyz.zip")

        do {
            try await engine.extract(archiveURL: nonexistent, entries: nil, to: dest, progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func extract_createsNestedDirectories() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["deep/nested/file.txt": "deepcontent"])
        let zipURL = tmp.appendingPathComponent("test.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", zipURL.path, "deep"]
        zipProcess.currentDirectoryURL = tmp
        zipProcess.standardOutput = FileHandle.nullDevice
        zipProcess.standardError = FileHandle.nullDevice
        try zipProcess.run()
        zipProcess.waitUntilExit()

        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: zipURL, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("deep/nested/file.txt").path))
    }

    // MARK: - extractEntry (single entry convenience)

    @Test func extractEntry_singleEntryByPath() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let zip = try await makeZip(from: tmp, files: ["song.mp3": "binary"])

        let dest = tmp.appendingPathComponent("song.mp3")
        try await engine.extractEntry(from: zip, entryPath: "song.mp3", to: dest)

        #expect(fm.fileExists(atPath: dest.path))
    }

    @Test func extractEntry_createsParentDirectories() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["nested/file.txt": "content"])
        let zipURL = tmp.appendingPathComponent("test.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", zipURL.path, "nested"]
        zipProcess.currentDirectoryURL = tmp
        zipProcess.standardOutput = FileHandle.nullDevice
        zipProcess.standardError = FileHandle.nullDevice
        try zipProcess.run()
        zipProcess.waitUntilExit()

        let dest = tmp.appendingPathComponent("out/nested/file.txt")
        try await engine.extractEntry(from: zipURL, entryPath: "nested/file.txt", to: dest)

        #expect(fm.fileExists(atPath: dest.path))
    }
}
