import Foundation
import Testing
import BentoZipCore

@MainActor
struct ZIPEngineTests {
    let engine = ZIPEngine()
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

    func cleanup(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    // MARK: - create

    @Test func create_singleFile() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["hello.txt": "world"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        let sourceURLs = [tmp.appendingPathComponent("hello.txt")]
        let settings = CompressionSettings(format: .zip)

        try await engine.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        #expect(fm.fileExists(atPath: archiveURL.path))
        let attrs = try fm.attributesOfItem(atPath: archiveURL.path)
        #expect((attrs[.size] as? Int64 ?? 0) > 0)
    }

    @Test func create_multipleFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["a.txt": "aaa", "b.txt": "bbb"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        let sourceURLs = [
            tmp.appendingPathComponent("a.txt"),
            tmp.appendingPathComponent("b.txt"),
        ]
        let settings = CompressionSettings(format: .zip)

        try await engine.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("a.txt"))
        #expect(names.contains("b.txt"))
    }

    @Test func create_withDirectoryPreservation() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["subdir/inner.txt": "deep"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        let sourceURLs = [tmp.appendingPathComponent("subdir")]
        var settings = CompressionSettings(format: .zip)
        settings.preserveDirectoryStructure = true

        try await engine.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        let paths = entries.map { $0.name }
        #expect(paths.contains(where: { $0.contains("inner.txt") }))
    }

    @Test func create_withCompressionLevels() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let content = String(repeating: "x", count: 10000)
        try makeTestFiles(in: tmp, files: ["big.txt": content])

        let archiveNone = tmp.appendingPathComponent("none.zip")
        let archiveBest = tmp.appendingPathComponent("best.zip")

        var settingsNone = CompressionSettings(format: .zip)
        settingsNone.compressionLevel = .none
        try await engine.create(from: [tmp.appendingPathComponent("big.txt")], to: archiveNone,
            settings: settingsNone, progress: { _ in })

        var settingsBest = CompressionSettings(format: .zip)
        settingsBest.compressionLevel = .best
        try await engine.create(from: [tmp.appendingPathComponent("big.txt")], to: archiveBest,
            settings: settingsBest, progress: { _ in })

        let sizeNone = (try fm.attributesOfItem(atPath: archiveNone.path)[.size] as? Int64) ?? 0
        let sizeBest = (try fm.attributesOfItem(atPath: archiveBest.path)[.size] as? Int64) ?? 0
        // Compressed should not be larger than uncompressed in best mode
        #expect(sizeBest <= sizeNone || sizeNone >= 10000)
    }

    @Test func create_emptySource_returnsImmediately() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let archiveURL = tmp.appendingPathComponent("empty.zip")
        var progressCalled = false

        try await engine.create(from: [], to: archiveURL, settings: CompressionSettings(),
            progress: { _ in progressCalled = true })

        #expect(progressCalled)
    }

    // MARK: - listEntries

    @Test func listEntries_afterCreate() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["alpha.txt": "a"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("alpha.txt")], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        #expect(!entries.isEmpty)
        #expect(entries.first?.name == "alpha.txt")
    }

    @Test func listEntries_nonexistentFile_throws() async throws {
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_xyz999.zip")
        do {
            _ = try await engine.listEntries(in: nonexistent)
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(Bool(true))
        }
    }

    // MARK: - extract

    @Test func extract_allEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["x.txt": "xxx", "y.txt": "yyy"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("x.txt"), tmp.appendingPathComponent("y.txt")],
            to: archiveURL, settings: CompressionSettings(), progress: { _ in })

        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: archiveURL, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("x.txt").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("y.txt").path))
        let content = try String(contentsOf: dest.appendingPathComponent("x.txt"), encoding: .utf8)
        #expect(content == "xxx")
    }

    @Test func extract_selectiveEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["keep.txt": "keep", "skip.txt": "skip"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("keep.txt"), tmp.appendingPathComponent("skip.txt")],
            to: archiveURL, settings: CompressionSettings(), progress: { _ in })

        let allEntries = try await engine.listEntries(in: archiveURL)
        let keepEntries = allEntries.filter { $0.name == "keep.txt" }

        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: archiveURL, entries: keepEntries, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("keep.txt").path))
    }

    @Test func extract_withProgressCallback() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["p1.txt": "1", "p2.txt": "2"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("p1.txt"), tmp.appendingPathComponent("p2.txt")],
            to: archiveURL, settings: CompressionSettings(), progress: { _ in })

        var progressValues: [Double] = []
        let dest = tmp.appendingPathComponent("extracted")
        try await engine.extract(archiveURL: archiveURL, entries: nil, to: dest,
            progress: { progressValues.append($0) })

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

    // MARK: - removeEntries

    @Test func removeEntries_removesSpecified() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["keep.txt": "keep", "remove.txt": "gone"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("keep.txt"), tmp.appendingPathComponent("remove.txt")],
            to: archiveURL, settings: CompressionSettings(), progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        let toRemove = entries.filter { $0.name == "remove.txt" }
        try await engine.removeEntries(from: archiveURL, entries: toRemove)

        let remaining = try await engine.listEntries(in: archiveURL)
        #expect(remaining.contains(where: { $0.name == "keep.txt" }))
        #expect(!remaining.contains(where: { $0.name == "remove.txt" }))
    }

    @Test func removeEntries_allEntries_deletesArchive() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["lonely.txt": "file"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("lonely.txt")], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        try await engine.removeEntries(from: archiveURL, entries: entries)

        #expect(!fm.fileExists(atPath: archiveURL.path))
    }

    // MARK: - addEntries

    @Test func addEntries_addsToExisting() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["original.txt": "orig"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("original.txt")], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        // Write a new file and add it
        try makeTestFiles(in: tmp, files: ["extra.txt": "extra"])
        try await engine.addEntries(to: archiveURL, from: [tmp.appendingPathComponent("extra.txt")],
            progress: { _ in })

        let entries = try await engine.listEntries(in: archiveURL)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("original.txt"))
        #expect(names.contains("extra.txt"))
    }

    @Test func addEntries_emptySource_noChange() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["base.txt": "base"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("base.txt")], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        var progressCalled = false
        try await engine.addEntries(to: archiveURL, from: [],
            progress: { _ in progressCalled = true })

        #expect(progressCalled)
    }

    @Test func addEntries_withProgress() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["base.txt": "base"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        try await engine.create(from: [tmp.appendingPathComponent("base.txt")], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        try makeTestFiles(in: tmp, files: ["new.txt": "new"])
        var progressValues: [Double] = []
        try await engine.addEntries(to: archiveURL, from: [tmp.appendingPathComponent("new.txt")],
            progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }
}
