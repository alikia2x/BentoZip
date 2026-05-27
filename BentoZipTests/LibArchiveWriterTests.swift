import Foundation
import Testing
import BentoZipCore

@MainActor
struct LibArchiveWriterTests {
    let writer = LibArchiveWriter()
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

    @Test func create_zipArchive() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["hello.txt": "world"])

        let archiveURL = tmp.appendingPathComponent("test.zip")
        let sourceURLs = [tmp.appendingPathComponent("hello.txt")]
        let settings = CompressionSettings(format: .zip)

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        #expect(fm.fileExists(atPath: archiveURL.path))
        let attrs = try fm.attributesOfItem(atPath: archiveURL.path)
        #expect((attrs[.size] as? Int64 ?? 0) > 0)
    }

    @Test func create_tarGzArchive() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["data.txt": "somedata"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [tmp.appendingPathComponent("data.txt")]
        let settings = CompressionSettings(format: .tarGz)

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        #expect(fm.fileExists(atPath: archiveURL.path))
    }

    @Test func create_7zArchive() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["note.txt": "hello"])

        let archiveURL = tmp.appendingPathComponent("test.7z")
        let sourceURLs = [tmp.appendingPathComponent("note.txt")]
        let settings = CompressionSettings(format: .sevenZip)

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        #expect(fm.fileExists(atPath: archiveURL.path))
    }

    @Test func create_preservesDirectoryStructure() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["sub/inner.txt": "deep"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [tmp.appendingPathComponent("sub")]
        var settings = CompressionSettings(format: .tarGz)
        settings.preserveDirectoryStructure = true

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        let paths = entries.map { $0.name }
        #expect(paths.contains(where: { $0.contains("inner.txt") }))
    }

    @Test func create_withExclusionPatterns() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["good.txt": "keep", ".DS_Store": "ignore"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [tmp.appendingPathComponent("good.txt")]
        var settings = CompressionSettings(format: .tarGz)
        settings.exclusionPatterns = [".DS_Store"]

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        // .DS_Store was not in sourceURLs anyway since we only added good.txt
        #expect(entries.contains(where: { $0.name == "good.txt" }))
    }

    @Test func create_emptySource_throws() async {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let settings = CompressionSettings(format: .tarGz)

        do {
            try await writer.create(from: [], to: archiveURL, settings: settings, progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch let error as ArchiveWriterError {
            if case .noEntriesToArchive = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected noEntriesToArchive, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func create_withProgressCallback() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["f1.txt": "111", "f2.txt": "222"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [
            tmp.appendingPathComponent("f1.txt"),
            tmp.appendingPathComponent("f2.txt"),
        ]
        let settings = CompressionSettings(format: .tarGz)

        var progressValues: [Double] = []
        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings,
            progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }

    // MARK: - listEntries

    @Test func listEntries_afterCreate() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["alpha.txt": "a", "beta.txt": "b"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [
            tmp.appendingPathComponent("alpha.txt"),
            tmp.appendingPathComponent("beta.txt"),
        ]
        let settings = CompressionSettings(format: .tarGz)

        try await writer.create(from: sourceURLs, to: archiveURL, settings: settings, progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("alpha.txt"))
        #expect(names.contains("beta.txt"))
    }

    @Test func listEntries_nonexistent_throws() async {
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_xyz.tar.gz")
        do {
            _ = try await writer.listEntries(in: nonexistent)
            #expect(Bool(false), "Expected error")
        } catch let error as ArchiveWriterError {
            if case .openFailed = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected openFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - extract (bulk)

    @Test func extract_allEntriesFromTarGz() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["x.txt": "xxx", "y.txt": "yyy"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [
            tmp.appendingPathComponent("x.txt"),
            tmp.appendingPathComponent("y.txt"),
        ]
        try await writer.create(from: sourceURLs, to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        let dest = tmp.appendingPathComponent("extracted")
        try await writer.extract(archiveURL: archiveURL, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("x.txt").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("y.txt").path))
        let contentX = try String(contentsOf: dest.appendingPathComponent("x.txt"), encoding: .utf8)
        #expect(contentX == "xxx")
    }

    @Test func extract_allEntriesFrom7z() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["z.txt": "zzz"])

        let archiveURL = tmp.appendingPathComponent("test.7z")
        let sourceURLs = [tmp.appendingPathComponent("z.txt")]
        try await writer.create(from: sourceURLs, to: archiveURL,
            settings: CompressionSettings(format: .sevenZip), progress: { _ in })

        let dest = tmp.appendingPathComponent("extracted")
        try await writer.extract(archiveURL: archiveURL, entries: nil, to: dest, progress: { _ in })

        #expect(fm.fileExists(atPath: dest.appendingPathComponent("z.txt").path))
    }

    @Test func extract_withProgress() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["a.txt": "a"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        try await writer.create(from: [tmp.appendingPathComponent("a.txt")], to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        var progressValues: [Double] = []
        let dest = tmp.appendingPathComponent("extracted")
        try await writer.extract(archiveURL: archiveURL, entries: nil, to: dest,
            progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }

    @Test func extract_nonexistentArchive_throws() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        let dest = tmp.appendingPathComponent("extracted")
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_xyz.tar.gz")

        do {
            try await writer.extract(archiveURL: nonexistent, entries: nil, to: dest, progress: { _ in })
            #expect(Bool(false), "Expected error")
        } catch let error as ArchiveWriterError {
            if case .openFailed = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected openFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - removeEntries

    @Test func removeEntries_removesSpecifiedEntries() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["keep.txt": "keep", "delete.txt": "gone"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        let sourceURLs = [
            tmp.appendingPathComponent("keep.txt"),
            tmp.appendingPathComponent("delete.txt"),
        ]
        try await writer.create(from: sourceURLs, to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        let toRemove = entries.filter { $0.name == "delete.txt" }
        #expect(!toRemove.isEmpty)

        try await writer.removeEntries(from: archiveURL, entries: toRemove)

        let remaining = try await writer.listEntries(in: archiveURL)
        #expect(!remaining.contains(where: { $0.name == "delete.txt" }))
        #expect(remaining.contains(where: { $0.name == "keep.txt" }))
    }

    @Test func removeEntries_removingAll_deletesArchive() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["sole.txt": "only"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        try await writer.create(from: [tmp.appendingPathComponent("sole.txt")], to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        try await writer.removeEntries(from: archiveURL, entries: entries)

        #expect(!fm.fileExists(atPath: archiveURL.path))
    }

    // MARK: - addEntries

    @Test func addEntries_addsNewFiles() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["original.txt": "orig"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        try await writer.create(from: [tmp.appendingPathComponent("original.txt")], to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        // Add a new file
        try makeTestFiles(in: tmp, files: ["new.txt": "new"])
        try await writer.addEntries(to: archiveURL, from: [tmp.appendingPathComponent("new.txt")],
            progress: { _ in })

        let entries = try await writer.listEntries(in: archiveURL)
        let names = Set(entries.map { $0.name })
        #expect(names.contains("original.txt"))
        #expect(names.contains("new.txt"))
    }

    @Test func addEntries_withProgress() async throws {
        let tmp = makeTempDir()
        defer { cleanup(tmp) }
        try makeTestFiles(in: tmp, files: ["base.txt": "base"])

        let archiveURL = tmp.appendingPathComponent("test.tar.gz")
        try await writer.create(from: [tmp.appendingPathComponent("base.txt")], to: archiveURL,
            settings: CompressionSettings(format: .tarGz), progress: { _ in })

        try makeTestFiles(in: tmp, files: ["extra.txt": "extra"])
        var progressValues: [Double] = []
        try await writer.addEntries(to: archiveURL, from: [tmp.appendingPathComponent("extra.txt")],
            progress: { progressValues.append($0) })

        #expect(!progressValues.isEmpty)
        #expect(progressValues.last == 1.0)
    }
}
