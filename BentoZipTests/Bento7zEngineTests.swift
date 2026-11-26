import Foundation
import os
import Testing
import BentoZipCore

@Suite(.serialized)
struct Bento7zEngineTests {
    private let engine = Bento7zEngine()
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("Bento7zTest_\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFiles(_ files: [String: String], in dir: URL) throws -> [URL] {
        var topLevel: Set<URL> = []
        for (relPath, content) in files {
            let fileURL = dir.appendingPathComponent(relPath)
            let parent = fileURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            let firstComponent = relPath.split(separator: "/").first.map(String.init) ?? relPath
            topLevel.insert(dir.appendingPathComponent(firstComponent))
        }
        return Array(topLevel).sorted { $0.path < $1.path }
    }

    // MARK: - Create / List / Extract across Formats

    @Test func roundTrip_allWritableFormats_includingTarBz2AndTarXz() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "hello.txt": "hello world",
            "nested/note.md": "# BentoZip"
        ], in: srcDir)

        for format in ArchiveFormat.allCases {
            let archiveURL = dir.appendingPathComponent("archive.\(format.fileExtension)")
            let settings = CompressionSettings(format: format, compressionLevel: .normal)
            var lastFraction = 0.0

            try await engine.create(from: inputs, to: archiveURL, settings: settings) { update in
                lastFraction = update.fractionCompleted
            }

            #expect(fm.fileExists(atPath: archiveURL.path))
            #expect(lastFraction == 1.0)

            let listResult = try await engine.listArchive(in: archiveURL)
            #expect(!listResult.entries.isEmpty)
            #expect(listResult.entries.contains(where: { $0.name == "hello.txt" && $0.size > 0 }))

            let outDir = dir.appendingPathComponent("out_\(format.fileExtension)")
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outDir, password: nil) { _ in }

            let extractedHello = outDir.appendingPathComponent("hello.txt")
            let extractedNote = outDir.appendingPathComponent("nested/note.md")
            #expect(fm.fileExists(atPath: extractedHello.path))
            #expect(fm.fileExists(atPath: extractedNote.path))
            #expect(try String(contentsOf: extractedHello, encoding: .utf8) == "hello world")
            #expect(try String(contentsOf: extractedNote, encoding: .utf8) == "# BentoZip")
        }
    }

    @Test func tarBz2AndTarXz_mutateAddAndRemoveEntries() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let initial = try makeFiles(["keep.txt": "keep"], in: srcDir)
        let extra = dir.appendingPathComponent("extra.txt")
        try "extra".write(to: extra, atomically: true, encoding: .utf8)

        for format in [ArchiveFormat.tarBz2, ArchiveFormat.tarXz] {
            let archiveURL = dir.appendingPathComponent("mutate.\(format.fileExtension)")
            try await engine.create(from: initial, to: archiveURL, settings: CompressionSettings(format: format)) { _ in }

            try await engine.addEntries(to: archiveURL, from: [extra], password: nil) { _ in }
            var entries = try await engine.listEntries(in: archiveURL)
            #expect(Set(entries.map(\.name)) == ["keep.txt", "extra.txt"])

            let toRemove = entries.filter { $0.name == "extra.txt" }
            try await engine.removeEntries(from: archiveURL, entries: toRemove)
            entries = try await engine.listEntries(in: archiveURL)
            #expect(entries.map(\.name) == ["keep.txt"])
        }
    }

    @Test func solid7z_listArchiveReturnsPositiveArchivePackedSize() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let repetitive = String(repeating: "BentoZipSolid7zPayload-", count: 500)
        let inputs = try makeFiles([
            "one.txt": repetitive,
            "two.txt": repetitive,
            "three.txt": repetitive
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("solid.7z")
        try await engine.create(
            from: inputs,
            to: archiveURL,
            settings: CompressionSettings(format: .sevenZip, compressionLevel: .best)
        ) { _ in }

        let result = try await engine.listArchive(in: archiveURL)
        let packed = try #require(result.archivePackedSize)
        #expect(packed > 0)
        #expect(packed < Int64(repetitive.utf8.count * 3))
    }

    @Test func mutateArchive_preservesExistingHiddenEntries() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "keep.txt": "keep",
            ".DS_Store": "metadata"
        ], in: srcDir)
        let extra = dir.appendingPathComponent("added.txt")
        try "added".write(to: extra, atomically: true, encoding: .utf8)

        let archiveURL = dir.appendingPathComponent("preserve_hidden.zip")
        // Create without exclusions so .DS_Store is inside the existing archive
        try await engine.create(
            from: inputs,
            to: archiveURL,
            settings: CompressionSettings(format: .zip, exclusionPatterns: [])
        ) { _ in }

        try await engine.addEntries(to: archiveURL, from: [extra], password: nil) { _ in }
        let entriesAfterAdd = try await engine.listEntries(in: archiveURL)
        #expect(Set(entriesAfterAdd.map(\.name)) == ["keep.txt", ".DS_Store", "added.txt"])

        let toRemove = entriesAfterAdd.filter { $0.name == "added.txt" }
        try await engine.removeEntries(from: archiveURL, entries: toRemove)
        let entriesAfterRemove = try await engine.listEntries(in: archiveURL)
        #expect(Set(entriesAfterRemove.map(\.name)) == ["keep.txt", ".DS_Store"])
    }

    @Test func pathTraversal_rejectedInExtractEntryAndRemoveEntries() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles(["safe.txt": "safe"], in: srcDir)
        let archiveURL = dir.appendingPathComponent("safe.zip")
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let outsideFile = dir.appendingPathComponent("outside_canary.txt")
        try "do-not-delete".write(to: outsideFile, atomically: true, encoding: .utf8)

        for unsafePath in ["../outside_canary.txt", "sub/../../outside_canary.txt", "..\\outside_canary.txt", "/etc/passwd", "C:/evil.txt"] {
            let destFile = dir.appendingPathComponent("out.txt")
            do {
                try await engine.extractEntry(from: archiveURL, entryPath: unsafePath, to: destFile)
                #expect(Bool(false), "Expected invalid path rejection for \(unsafePath)")
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error {
                    #expect(code == "INVALID_PATH")
                } else {
                    #expect(Bool(false), "Expected operationFailed INVALID_PATH, got \(error)")
                }
            }

            let maliciousEntry = FileEntry(
                url: URL(fileURLWithPath: "/archive-root/outside_canary.txt"),
                name: "outside_canary.txt",
                isFromArchive: true,
                archiveRelativePath: unsafePath
            )
            do {
                try await engine.removeEntries(from: archiveURL, entries: [maliciousEntry])
                #expect(Bool(false), "Expected removeEntries to reject \(unsafePath)")
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error {
                    #expect(code == "INVALID_PATH")
                } else {
                    #expect(Bool(false), "Expected operationFailed INVALID_PATH, got \(error)")
                }
            }
        }

        #expect(fm.fileExists(atPath: outsideFile.path))
    }

    @Test func create_emptySources_completesImmediately() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let archiveURL = dir.appendingPathComponent("empty.zip")
        var progressCalled = false
        try await engine.create(from: [], to: archiveURL, settings: CompressionSettings()) { _ in
            progressCalled = true
        }
        #expect(progressCalled)
    }

    // MARK: - Metadata & Progress

    @Test func listEntries_populatesSizePackedSizeAndModificationDate() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let payload = String(repeating: "BentoZip ", count: 200)
        let inputs = try makeFiles(["sample.txt": payload], in: srcDir)

        let archiveURL = dir.appendingPathComponent("meta.zip")
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let entries = try await engine.listEntries(in: archiveURL)
        let entry = try #require(entries.first(where: { $0.name == "sample.txt" }))
        #expect(entry.size == Int64(payload.utf8.count))
        #expect(entry.packedSize != nil)
        #expect(entry.modificationDate != nil)
        #expect(entry.isFromArchive)
        #expect(!entry.isEncrypted)
    }

    @Test func createAndExtract_emitProgressUpdates() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "a.txt": String(repeating: "A", count: 4096),
            "b.txt": String(repeating: "B", count: 4096)
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("progress.7z")
        var createUpdates: [ArchiveProgress] = []
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .sevenZip)) {
            createUpdates.append($0)
        }
        #expect(!createUpdates.isEmpty)
        #expect(createUpdates.last?.fractionCompleted == 1.0)

        var extractUpdates: [ArchiveProgress] = []
        let outDir = dir.appendingPathComponent("out")
        try await engine.extract(archiveURL: archiveURL, entries: nil, to: outDir, password: nil) {
            extractUpdates.append($0)
        }
        #expect(!extractUpdates.isEmpty)
        #expect(extractUpdates.last?.fractionCompleted == 1.0)
    }

    // MARK: - Selective Extract & extractEntry

    @Test func extract_selectiveEntries_onlyExtractsRequestedFiles() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "keep.txt": "keep",
            "skip.txt": "skip",
            "sub/also_keep.txt": "sub"
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("selective.zip")
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let allEntries = try await engine.listEntries(in: archiveURL)
        let keepEntry = try #require(allEntries.first(where: { $0.name == "keep.txt" }))

        let outDir = dir.appendingPathComponent("out")
        try await engine.extract(archiveURL: archiveURL, entries: [keepEntry], to: outDir, password: nil) { _ in }

        #expect(fm.fileExists(atPath: outDir.appendingPathComponent("keep.txt").path))
        #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("skip.txt").path))
    }

    @Test func extractEntry_singleNestedEntry() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "folder/target.txt": "target-data",
            "folder/other.txt": "other-data"
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("single.zip")
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        let entries = try await engine.listEntries(in: archiveURL)
        let target = try #require(entries.first(where: { $0.name == "target.txt" }))
        let relPath = try #require(target.archiveRelativePath)

        let destFile = dir.appendingPathComponent("dragged/target.txt")
        try await engine.extractEntry(from: archiveURL, entryPath: relPath, to: destFile)

        #expect(fm.fileExists(atPath: destFile.path))
        #expect(try String(contentsOf: destFile, encoding: .utf8) == "target-data")
    }

    // MARK: - Exclusion Patterns

    @Test func create_exclusionPatterns_skipsMatchingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "root/.DS_Store": "junk",
            "root/app.swift": "print(1)",
            "root/debug.log": "log"
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("filtered.zip")
        let settings = CompressionSettings(
            format: .zip,
            exclusionPatterns: [".DS_Store", "*.log"]
        )
        try await engine.create(from: inputs, to: archiveURL, settings: settings) { _ in }

        let entries = try await engine.listEntries(in: archiveURL)
        let names = Set(entries.map(\.name))
        #expect(names.contains("app.swift"))
        #expect(!names.contains(".DS_Store"))
        #expect(!names.contains("debug.log"))
    }

    // MARK: - Password Protection

    @Test func passwordProtected7z_requiresAndValidatesPassword() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles(["secret.txt": "top-secret"], in: srcDir)

        let archiveURL = dir.appendingPathComponent("secret.7z")
        let settings = CompressionSettings(format: .sevenZip, password: "correct-horse")
        try await engine.create(from: inputs, to: archiveURL, settings: settings) { _ in }

        // Attempting extraction without password fails with passwordRequired or wrongPassword
        let outFail = dir.appendingPathComponent("out_fail")
        do {
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outFail, password: nil) { _ in }
            #expect(Bool(false), "Expected password error when extracting without password")
        } catch let err as Bento7zError {
            #expect(err == .passwordRequired || err == .wrongPassword)
        }

        // Attempting extraction with wrong password fails
        let outWrong = dir.appendingPathComponent("out_wrong")
        do {
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outWrong, password: "wrong-password") { _ in }
            #expect(Bool(false), "Expected password error when extracting with wrong password")
        } catch let err as Bento7zError {
            #expect(err == .wrongPassword || err == .passwordRequired)
        }

        // Extracting with correct password succeeds
        let outOk = dir.appendingPathComponent("out_ok")
        try await engine.extract(archiveURL: archiveURL, entries: nil, to: outOk, password: "correct-horse") { _ in }
        #expect(try String(contentsOf: outOk.appendingPathComponent("secret.txt"), encoding: .utf8) == "top-secret")
    }

    // MARK: - Add & Remove Entries

    @Test func addAndRemoveEntries_updatesArchiveCleanly() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let initial = try makeFiles(["keep.txt": "keep"], in: srcDir)
        let extra = dir.appendingPathComponent("extra.txt")
        try "extra".write(to: extra, atomically: true, encoding: .utf8)

        let archiveURL = dir.appendingPathComponent("mutate.zip")
        try await engine.create(from: initial, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        try await engine.addEntries(to: archiveURL, from: [extra], password: nil) { _ in }
        var entries = try await engine.listEntries(in: archiveURL)
        #expect(Set(entries.map(\.name)) == ["keep.txt", "extra.txt"])

        let toRemove = entries.filter { $0.name == "extra.txt" }
        try await engine.removeEntries(from: archiveURL, entries: toRemove)

        entries = try await engine.listEntries(in: archiveURL)
        #expect(entries.map(\.name) == ["keep.txt"])

        // Removing remaining entry deletes archive
        try await engine.removeEntries(from: archiveURL, entries: entries)
        #expect(!fm.fileExists(atPath: archiveURL.path))
    }

    // MARK: - Cancellation & Protocol Edge Cases (Mock Binary)

    @Test func execute_cancellationTerminatesSubprocessWithoutHanging() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let dummyArchive = dir.appendingPathComponent("dummy.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: dummyArchive)

        let mockScript = dir.appendingPathComponent("mock_bento7z.sh")
        let script = """
        #!/bin/sh
        read line
        echo '{"id":"1","type":"progress","data":{"processed_bytes":10,"total_bytes":100,"current_file":"big.bin"}}'
        sleep 30
        """
        try script.write(to: mockScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)

        let mockEngine = Bento7zEngine(binaryPath: mockScript.path)

        let start = Date()
        let task = Task {
            _ = try await mockEngine.listEntries(in: dummyArchive)
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            #expect(Bool(false), "Expected CancellationError")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(start) < 5.0)
        }
    }

    @Test func execute_heavyStderrDoesNotDeadlockAndParsesEventsAndErrors() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let dummyArchive = dir.appendingPathComponent("dummy.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: dummyArchive)

        let mockScript = dir.appendingPathComponent("mock_bento7z.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        req = json.loads(sys.stdin.readline())
        sys.stderr.write("warning\\n" * 20000)
        sys.stderr.flush()
        cmd = req["command"]
        if cmd == "list":
            print(json.dumps({
                "id": req["id"],
                "type": "result",
                "data": {
                    "items": [{
                        "index": 0,
                        "name": "doc.pdf",
                        "path": "docs/doc.pdf",
                        "extension": "pdf",
                        "is_dir": False,
                        "size": 1000,
                        "packed_size": 450,
                        "crc": 123,
                        "encrypted": True,
                        "modified_at": 1700000000
                    }]
                }
            }))
        elif cmd == "extract":
            print(json.dumps({"id": req["id"], "type": "file", "data": {"path": "docs/doc.pdf"}}))
            print(json.dumps({"id": req["id"], "type": "progress", "data": {"processed_bytes": 50, "total_bytes": 100, "current_file": "docs/doc.pdf"}}))
            if req["params"].get("password") == "bad":
                print(json.dumps({"id": req["id"], "type": "error", "data": {"code": "WRONG_PASSWORD", "message": "wrong"}}))
            elif "password" not in req["params"]:
                print(json.dumps({"id": req["id"], "type": "error", "data": {"code": "PASSWORD_REQUIRED", "message": "need pw"}}))
            else:
                print(json.dumps({"id": req["id"], "type": "result", "data": {"ok": True}}))
        """
        try script.write(to: mockScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)

        let mockEngine = Bento7zEngine(binaryPath: mockScript.path)

        let entries = try await mockEngine.listEntries(in: dummyArchive)
        let entry = try #require(entries.first)
        #expect(entry.name == "doc.pdf")
        #expect(entry.packedSize == 450)
        #expect(entry.isEncrypted)
        #expect(entry.modificationDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entry.archiveRelativePath == "docs/doc.pdf")

        let outDir = dir.appendingPathComponent("out")
        do {
            try await mockEngine.extract(archiveURL: dummyArchive, entries: entries, to: outDir, password: nil) { _ in }
            #expect(Bool(false), "Expected passwordRequired")
        } catch let err as Bento7zError {
            #expect(err == .passwordRequired)
        }

        do {
            try await mockEngine.extract(archiveURL: dummyArchive, entries: entries, to: outDir, password: "bad") { _ in }
            #expect(Bool(false), "Expected wrongPassword")
        } catch let err as Bento7zError {
            #expect(err == .wrongPassword)
        }

        var seenFiles: [String] = []
        try await mockEngine.extract(archiveURL: dummyArchive, entries: entries, to: outDir, password: "good") { update in
            if let file = update.currentFile {
                seenFiles.append(file)
            }
        }
        #expect(seenFiles.contains("docs/doc.pdf"))
    }

    @Test func execute_malformedStdoutAndNonZeroExitSurfacesDiagnostic() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let dummyArchive = dir.appendingPathComponent("dummy.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: dummyArchive)

        let mockScript = dir.appendingPathComponent("mock_malformed.sh")
        let script = """
        #!/bin/sh
        read line
        echo 'not-valid-json-panic'
        exit 2
        """
        try script.write(to: mockScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)

        let mockEngine = Bento7zEngine(binaryPath: mockScript.path)
        do {
            _ = try await mockEngine.listEntries(in: dummyArchive)
            #expect(Bool(false), "Expected processError")
        } catch let err as Bento7zError {
            if case .processError(let detail) = err {
                #expect(detail.contains("2"))
                #expect(detail.contains("not-valid-json-panic"))
            } else {
                #expect(Bool(false), "Expected processError, got \(err)")
            }
        }
    }

    @Test func archiveCacheManager_persistsInvalidatesStaleAndSkipsEncrypted() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let cacheDir = dir.appendingPathComponent("Cache")
        let cache = ArchiveCacheManager(directory: cacheDir, maxCacheMB: 16)

        let tarGz = dir.appendingPathComponent("sample.tar.gz")
        try Data(repeating: 0x1F, count: 1024).write(to: tarGz)

        // Encrypted archives must never be cached on disk
        #expect(cache.tarCacheURL(for: tarGz, isEncrypted: true) == nil)

        // Non-compound ZIP must not use tar cache
        let zipFile = dir.appendingPathComponent("sample.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: zipFile)
        #expect(cache.tarCacheURL(for: zipFile, isEncrypted: false) == nil)

        // Compound tar.gz gets a deterministic cache path and tracks disk usage
        let cacheURL = try #require(cache.tarCacheURL(for: tarGz, isEncrypted: false))
        try Data(repeating: 0xAA, count: 4096).write(to: cacheURL)
        cache.recordMaterializedTar(for: tarGz, at: cacheURL)
        #expect(cache.stats().entryCount == 1)
        #expect(cache.stats().totalBytes == 4096)

        // Modifying the source archive invalidates the old cache entry
        try Data(repeating: 0x2F, count: 2048).write(to: tarGz)
        let refreshedURL = try #require(cache.tarCacheURL(for: tarGz, isEncrypted: false))
        #expect(refreshedURL != cacheURL)
        #expect(!fm.fileExists(atPath: cacheURL.path))

        cache.clearCache()
        #expect(cache.stats().entryCount == 0)
        #expect(cache.stats().totalBytes == 0)
    }

    @Test func binaryServer_compoundTarGzPersistentCacheAndOuterProgress() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("Payload")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 128 * 1024).write(to: srcDir.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 128 * 1024).write(to: srcDir.appendingPathComponent("b.bin"))

        let cache = ArchiveCacheManager(directory: dir.appendingPathComponent("TarCache"), maxCacheMB: 64)
        let testEngine = Bento7zEngine(cacheManager: cache)
        let tarGzURL = dir.appendingPathComponent("bundle.tar.gz")

        try await testEngine.create(
            from: [srcDir],
            to: tarGzURL,
            settings: CompressionSettings(format: .tarGz, compressionLevel: .fast)
        ) { _ in }

        let progressLock = NSLock()
        var sawUnpackingOuter = false
        let firstList = try await testEngine.listArchive(in: tarGzURL, password: nil) { update in
            if update.stage == .unpackingOuter {
                progressLock.withLock { sawUnpackingOuter = true }
            }
        }
        #expect(firstList.entries.count == 2)
        #expect(sawUnpackingOuter)
        #expect(cache.stats().entryCount == 1)
        #expect(cache.stats().totalBytes > 0)

        // Second open reuses the persistent cached tar without re-decompressing outer stream
        var sawOuterOnSecondOpen = false
        let secondList = try await testEngine.listArchive(in: tarGzURL, password: nil) { update in
            if update.stage == .unpackingOuter {
                progressLock.withLock { sawOuterOnSecondOpen = true }
            }
        }
        #expect(secondList.entries.count == 2)
        #expect(!sawOuterOnSecondOpen)
    }

    @Test func binaryServer_concurrentInteractiveAndInPlaceZip7zMutations() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("alpha.txt")
        let fileB = dir.appendingPathComponent("beta.txt")
        let fileC = dir.appendingPathComponent("gamma.txt")
        try "alpha-data".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta-data".write(to: fileB, atomically: true, encoding: .utf8)
        try "gamma-data".write(to: fileC, atomically: true, encoding: .utf8)

        let testEngine = Bento7zEngine()
        for format in [ArchiveFormat.zip, ArchiveFormat.sevenZip] {
            let archiveURL = dir.appendingPathComponent("inplace_\(format.fileExtension).\(format.fileExtension)")
            try await testEngine.create(
                from: [fileA, fileB],
                to: archiveURL,
                settings: CompressionSettings(format: format, compressionLevel: .fast)
            ) { _ in }

            // Concurrent interactive requests over the multiplexed binary worker
            let outAlpha = dir.appendingPathComponent("out_\(format.fileExtension)_alpha.txt")
            let outBeta = dir.appendingPathComponent("out_\(format.fileExtension)_beta.txt")
            async let listTask = testEngine.listArchive(in: archiveURL, password: nil)
            async let extractA: Void = testEngine.extractEntry(from: archiveURL, entryPath: "alpha.txt", to: outAlpha)
            async let extractB: Void = testEngine.extractEntry(from: archiveURL, entryPath: "beta.txt", to: outBeta)
            let (listed, _, _) = try await (listTask, extractA, extractB)
            #expect(Set(listed.entries.map(\.name)) == ["alpha.txt", "beta.txt"])
            #expect(try String(contentsOf: outAlpha, encoding: .utf8) == "alpha-data")
            #expect(try String(contentsOf: outBeta, encoding: .utf8) == "beta-data")

            // In-place add
            try await testEngine.addEntries(to: archiveURL, from: [fileC], password: nil) { _ in }
            let afterAdd = try await testEngine.listEntries(in: archiveURL)
            #expect(Set(afterAdd.map(\.name)) == ["alpha.txt", "beta.txt", "gamma.txt"])

            // In-place delete
            let betaEntry = try #require(afterAdd.first(where: { $0.name == "beta.txt" }))
            try await testEngine.removeEntries(from: archiveURL, entries: [betaEntry], password: nil)
            let afterDelete = try await testEngine.listEntries(in: archiveURL)
            #expect(Set(afterDelete.map(\.name)) == ["alpha.txt", "gamma.txt"])
        }
    }

    @Test func compoundTarGz_compressListExtractProgressIsMonotonicAndTyped() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let cacheRoot = dir.appendingPathComponent("tar_cache")
        let cacheMgr = ArchiveCacheManager(directory: cacheRoot, maxCacheMB: 64)
        let testEngine = Bento7zEngine(cacheManager: cacheMgr)

        // ~4 MB of mildly compressible data so both tar & gzip stages emit progress reliably
        let srcDir = dir.appendingPathComponent("payload")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let chunk = Data((0..<65_536).map { UInt8(($0 &* 31 ^ ($0 >> 3)) & 0xFF) })
        for idx in 0..<4 {
            var fileData = Data(capacity: 1_048_576)
            for _ in 0..<16 { fileData.append(chunk) }
            try fileData.write(to: srcDir.appendingPathComponent("part_\(idx).bin"))
        }

        let archiveURL = dir.appendingPathComponent("bundle.tar.gz")

        // 1. Compress: packingTar (0..0.25) -> compressingOuter (0.25..1.0), strictly monotonic
        let compressEvents = OSAllocatedUnfairLock(initialState: [ArchiveProgress]())
        try await testEngine.create(
            from: [srcDir],
            to: archiveURL,
            settings: CompressionSettings(format: .tarGz, compressionLevel: .fast)
        ) { progress in
            compressEvents.withLock { $0.append(progress) }
        }
        let cLog = compressEvents.withLock { $0 }
        #expect(cLog.contains { $0.stage == .packingTar && ($0.totalBytes ?? 0) > 0 })
        #expect(cLog.contains { $0.stage == .compressingOuter && ($0.totalBytes ?? 0) > 0 })
        for pair in zip(cLog, cLog.dropFirst()) {
            #expect(pair.1.fractionCompleted >= pair.0.fractionCompleted)
        }

        // 2. List (cache miss): unpackingOuter (non-zero totalBytes) -> readingEntries, monotonic
        let listEvents = OSAllocatedUnfairLock(initialState: [ArchiveProgress]())
        let listed = try await testEngine.listArchive(in: archiveURL, password: nil) { progress in
            listEvents.withLock { $0.append(progress) }
        }
        #expect(!listed.entries.isEmpty)
        let lLog = listEvents.withLock { $0 }
        #expect(lLog.contains { $0.stage == .unpackingOuter && ($0.totalBytes ?? 0) > 0 })
        #expect(lLog.contains { $0.stage == .readingEntries })
        for pair in zip(lLog, lLog.dropFirst()) {
            #expect(pair.1.fractionCompleted >= pair.0.fractionCompleted)
        }

        // 3. Extract (clear cache to force cache-miss two-phase extract): unpackingOuter -> extractingInner
        cacheMgr.clearCache()
        let extractDir = dir.appendingPathComponent("extracted")
        let extractEvents = OSAllocatedUnfairLock(initialState: [ArchiveProgress]())
        try await testEngine.extract(
            archiveURL: archiveURL,
            entries: nil,
            to: extractDir,
            password: nil
        ) { progress in
            extractEvents.withLock { $0.append(progress) }
        }
        let eLog = extractEvents.withLock { $0 }
        #expect(eLog.contains { $0.stage == .unpackingOuter && ($0.totalBytes ?? 0) > 0 })
        #expect(eLog.contains { $0.stage == .extractingInner && ($0.totalBytes ?? 0) > 0 })
        for pair in zip(eLog, eLog.dropFirst()) {
            #expect(pair.1.fractionCompleted >= pair.0.fractionCompleted)
        }
    }

    @Test @MainActor func transferTask_resetsPerStageThroughputWithoutBackwardProgressJump() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let task = TransferTask(kind: .compress, title: "Compressing…", totalBytes: 1000, startedAt: t0)

        task.apply(
            ArchiveProgress(
                fractionCompleted: 0.25,
                currentFile: "a.bin",
                processedBytes: 1000,
                totalBytes: 1000,
                isFileEvent: true,
                stage: .packingTar
            ),
            now: t0.addingTimeInterval(1.0)
        )
        #expect(task.stage == .packingTar)
        #expect(task.fractionCompleted == 0.25)
        #expect(task.processedBytes == 1000)
        #expect(task.bytesPerSecond > 0)

        // Transition into compressingOuter: processedBytes & speed reset cleanly while fraction stays monotonic
        task.apply(
            ArchiveProgress(
                fractionCompleted: 0.25,
                currentFile: "archive.tar",
                processedBytes: 0,
                totalBytes: 1024,
                stage: .compressingOuter
            ),
            now: t0.addingTimeInterval(1.1)
        )
        #expect(task.stage == .compressingOuter)
        #expect(task.fractionCompleted == 0.25)
        #expect(task.processedBytes == 0)
        #expect(task.totalBytes == 1024)
        #expect(task.bytesPerSecond == 0)

        task.apply(
            ArchiveProgress(
                fractionCompleted: 0.625,
                currentFile: "archive.tar",
                processedBytes: 512,
                totalBytes: 1024,
                stage: .compressingOuter
            ),
            now: t0.addingTimeInterval(2.1)
        )
        #expect(task.fractionCompleted == 0.625)
        #expect(task.processedBytes == 512)
        #expect(task.bytesPerSecond > 400 && task.bytesPerSecond < 600)
    }

    @Test func zstd_rawAndCompoundTarZstListAndExtract() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // Create a valid uncompressed .tar with one file, then inspect raw Zstd magic frame via engine.
        // Valid Zstd single-segment raw frame decoding to "zstd-ok\n":
        let zstURL = dir.appendingPathComponent("note.txt.zst")
        let zstFrame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x08, 0x41, 0x00, 0x00]) + Data("zstd-ok\n".utf8)
        try zstFrame.write(to: zstURL)

        let entries = try await engine.listEntries(in: zstURL)
        #expect(entries.count == 1)
        #expect(entries[0].name == "note.txt")

        let outDir = dir.appendingPathComponent("zst_out")
        try await engine.extract(archiveURL: zstURL, entries: nil, to: outDir, password: nil) { _ in }
        let extractedText = try String(contentsOf: outDir.appendingPathComponent("note.txt"), encoding: .utf8)
        #expect(extractedText == "zstd-ok\n")
    }

    @Test func splitVolumes_createListExtractAndReportMissingVolume() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let payload = dir.appendingPathComponent("large.bin")
        var bytes = Data(capacity: 260_000)
        for i in 0..<260_000 {
            bytes.append(UInt8((i &* 73 ^ (i >> 5)) & 0xFF))
        }
        try bytes.write(to: payload)

        for format in [ArchiveFormat.sevenZip, ArchiveFormat.zip] {
            let baseURL = dir.appendingPathComponent("split_\(format.fileExtension).\(format.fileExtension)")
            try await engine.create(
                from: [payload],
                to: baseURL,
                settings: CompressionSettings(
                    format: format,
                    compressionLevel: .none,
                    volumeSizeBytes: 100_000
                )
            ) { _ in }

            let vol1 = URL(fileURLWithPath: baseURL.path + ".001")
            let vol2 = URL(fileURLWithPath: baseURL.path + ".002")
            #expect(fm.fileExists(atPath: vol1.path))
            #expect(fm.fileExists(atPath: vol2.path))

            let listed = try await engine.listEntries(in: vol1)
            #expect(listed.map(\.name) == ["large.bin"])

            let outDir = dir.appendingPathComponent("out_\(format.fileExtension)")
            try await engine.extract(archiveURL: vol1, entries: nil, to: outDir, password: nil) { _ in }
            let roundTrip = try Data(contentsOf: outDir.appendingPathComponent("large.bin"))
            #expect(roundTrip == bytes)

            // Deleting second volume produces explicit missingVolume error
            try fm.removeItem(at: vol2)
            do {
                _ = try await engine.listEntries(in: vol1)
                Issue.record("Expected missingVolume error when .002 is removed")
            } catch let error as Bento7zError {
                if case .missingVolume(let msg) = error {
                    #expect(msg.contains(".002"))
                } else {
                    Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }

    @Test func zipAES256_encryptsAndDecryptsArchive() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let secretFile = dir.appendingPathComponent("secret.txt")
        try "top-secret-aes256".write(to: secretFile, atomically: true, encoding: .utf8)

        let zipURL = dir.appendingPathComponent("aes256.zip")
        try await engine.create(
            from: [secretFile],
            to: zipURL,
            settings: CompressionSettings(
                format: .zip,
                compressionLevel: .fast,
                password: "pass-aes-256",
                zipEncryptionMethod: .aes256
            )
        ) { _ in }

        let listed = try await engine.listEntries(in: zipURL)
        #expect(listed.first?.isEncrypted == true)

        let badOut = dir.appendingPathComponent("bad_out")
        do {
            try await engine.extract(archiveURL: zipURL, entries: nil, to: badOut, password: "wrong") { _ in }
            Issue.record("Expected wrongPassword error")
        } catch let error as Bento7zError {
            #expect(error == .wrongPassword)
        }

        let goodOut = dir.appendingPathComponent("good_out")
        try await engine.extract(archiveURL: zipURL, entries: nil, to: goodOut, password: "pass-aes-256") { _ in }
        #expect(try String(contentsOf: goodOut.appendingPathComponent("secret.txt"), encoding: .utf8) == "top-secret-aes256")
    }

    @Test func legacyZipEncoding_repairsGBKAndShiftJISFilenames() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        func writeRawZip(at url: URL, pathData: Data, payload: Data) throws {
            var crc: UInt32 = 0xFFFF_FFFF
            for b in payload {
                var c = crc ^ UInt32(b)
                for _ in 0..<8 {
                    c = (c & 1) != 0 ? ((c >> 1) ^ 0xEDB8_8320) : (c >> 1)
                }
                crc = c
            }
            crc ^= 0xFFFF_FFFF

            var lh = Data()
            func appendU16(_ d: inout Data, _ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
            func appendU32(_ d: inout Data, _ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
            appendU32(&lh, 0x04034B50); appendU16(&lh, 20); appendU16(&lh, 0); appendU16(&lh, 0)
            appendU16(&lh, 0); appendU16(&lh, 0); appendU32(&lh, crc)
            appendU32(&lh, UInt32(payload.count)); appendU32(&lh, UInt32(payload.count))
            appendU16(&lh, UInt16(pathData.count)); appendU16(&lh, 0)
            lh.append(pathData); lh.append(payload)

            var cd = Data()
            appendU32(&cd, 0x02014B50); appendU16(&cd, 20); appendU16(&cd, 20); appendU16(&cd, 0); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, crc)
            appendU32(&cd, UInt32(payload.count)); appendU32(&cd, UInt32(payload.count))
            appendU16(&cd, UInt16(pathData.count)); appendU16(&cd, 0); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, 0); appendU32(&cd, 0)
            cd.append(pathData)

            var eocd = Data()
            appendU32(&eocd, 0x06054B50); appendU16(&eocd, 0); appendU16(&eocd, 0)
            appendU16(&eocd, 1); appendU16(&eocd, 1)
            appendU32(&eocd, UInt32(cd.count)); appendU32(&eocd, UInt32(lh.count)); appendU16(&eocd, 0)

            var zipBytes = Data()
            zipBytes.append(lh); zipBytes.append(cd); zipBytes.append(eocd)
            try zipBytes.write(to: url)
        }

        // GBK bytes for "目录/测试.txt": C4 BF C2 BC 2F B2 E2 CA D4 2E 74 78 74
        let gbkURL = dir.appendingPathComponent("gbk_legacy.zip")
        let gbkBytes = Data([0xC4, 0xBF, 0xC2, 0xBC, 0x2F, 0xB2, 0xE2, 0xCA, 0xD4, 0x2E, 0x74, 0x78, 0x74])
        try writeRawZip(at: gbkURL, pathData: gbkBytes, payload: Data("gbk-ok".utf8))

        let gbkEntries = try await engine.listEntries(in: gbkURL)
        #expect(gbkEntries.first?.name == "测试.txt")
        #expect(gbkEntries.first?.archiveRelativePath == "目录/测试.txt")

        let gbkOut = dir.appendingPathComponent("gbk_out")
        try await engine.extract(archiveURL: gbkURL, entries: nil, to: gbkOut, password: nil) { _ in }
        #expect(fm.fileExists(atPath: gbkOut.appendingPathComponent("目录/测试.txt").path))

        // Selective single-entry extraction using the repaired UTF-8 path
        let singleOut = dir.appendingPathComponent("single_测试.txt")
        try await engine.extractEntry(from: gbkURL, entryPath: "目录/测试.txt", to: singleOut)
        #expect(try String(contentsOf: singleOut, encoding: .utf8) == "gbk-ok")

        // Shift-JIS bytes for "テスト.txt": 83 65 83 58 83 67 2E 74 78 74
        let sjisURL = dir.appendingPathComponent("sjis_legacy.zip")
        let sjisBytes = Data([0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x2E, 0x74, 0x78, 0x74])
        try writeRawZip(at: sjisURL, pathData: sjisBytes, payload: Data("sjis-ok".utf8))

        let sjisEntries = try await engine.listEntries(in: sjisURL)
        #expect(sjisEntries.first?.name == "テスト.txt")
    }

    @Test func appleArchive_roundTripCreateListExtract() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("Bundle")
        try fm.createDirectory(at: srcDir.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        try "hello aar".write(to: srcDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: srcDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "deep content".write(to: srcDir.appendingPathComponent("Nested/deep.txt"), atomically: true, encoding: .utf8)

        let aarURL = dir.appendingPathComponent("sample.aar")
        try await engine.create(
            from: [srcDir],
            to: aarURL,
            settings: CompressionSettings(
                format: .aar,
                compressionLevel: .normal,
                preserveDirectoryStructure: true,
                exclusionPatterns: [".DS_Store"]
            )
        ) { _ in }

        let listed = try await engine.listArchive(in: aarURL)
        // Single top directory "Bundle" unwrapped -> ["Nested", "readme.txt"], without .DS_Store
        let names = Set(listed.entries.map(\.name))
        #expect(names == ["Nested", "readme.txt"])
        #expect(!names.contains(".DS_Store"))

        let outDir = dir.appendingPathComponent("aar_out")
        try await engine.extract(archiveURL: aarURL, entries: nil, to: outDir, password: nil) { _ in }
        #expect(try String(contentsOf: outDir.appendingPathComponent("Bundle/readme.txt"), encoding: .utf8) == "hello aar")
        #expect(try String(contentsOf: outDir.appendingPathComponent("Bundle/Nested/deep.txt"), encoding: .utf8) == "deep content")

        let quickFile = dir.appendingPathComponent("quick_deep.txt")
        try await engine.extractEntry(from: aarURL, entryPath: "Bundle/Nested/deep.txt", to: quickFile)
        #expect(try String(contentsOf: quickFile, encoding: .utf8) == "deep content")
    }

    // MARK: - P0 Engine Capabilities

    private func writeRawLegacyZip(at url: URL, pathData: Data, payload: Data) throws {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in payload {
            var c = crc ^ UInt32(b)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? ((c >> 1) ^ 0xEDB8_8320) : (c >> 1)
            }
            crc = c
        }
        crc ^= 0xFFFF_FFFF

        var lh = Data()
        func appendU16(_ d: inout Data, _ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func appendU32(_ d: inout Data, _ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        appendU32(&lh, 0x04034B50); appendU16(&lh, 20); appendU16(&lh, 0); appendU16(&lh, 0)
        appendU16(&lh, 0); appendU16(&lh, 0); appendU32(&lh, crc)
        appendU32(&lh, UInt32(payload.count)); appendU32(&lh, UInt32(payload.count))
        appendU16(&lh, UInt16(pathData.count)); appendU16(&lh, 0)
        lh.append(pathData); lh.append(payload)

        var cd = Data()
        appendU32(&cd, 0x02014B50); appendU16(&cd, 20); appendU16(&cd, 20); appendU16(&cd, 0); appendU16(&cd, 0)
        appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, crc)
        appendU32(&cd, UInt32(payload.count)); appendU32(&cd, UInt32(payload.count))
        appendU16(&cd, UInt16(pathData.count)); appendU16(&cd, 0); appendU16(&cd, 0)
        appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, 0); appendU32(&cd, 0)
        cd.append(pathData)

        var eocd = Data()
        appendU32(&eocd, 0x06054B50); appendU16(&eocd, 0); appendU16(&eocd, 0)
        appendU16(&eocd, 1); appendU16(&eocd, 1)
        appendU32(&eocd, UInt32(cd.count)); appendU32(&eocd, UInt32(lh.count)); appendU16(&eocd, 0)

        var zipBytes = Data()
        zipBytes.append(lh); zipBytes.append(cd); zipBytes.append(eocd)
        try zipBytes.write(to: url)
    }

    @Test func testArchive_validZip7zAndTarGz_passesAndReportsItemCounts() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "one.txt": "payload one",
            "folder/two.txt": "payload two"
        ], in: srcDir)

        for format in [ArchiveFormat.zip, .sevenZip, .tarGz] {
            let archiveURL = dir.appendingPathComponent("valid.\(format.fileExtension)")
            try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: format)) { _ in }

            let result = try await engine.testArchive(at: archiveURL)
            #expect(result.itemsCount >= 2)
        }
    }

    @Test func testArchive_corruptedZip_throwsCorruptArchiveError() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let payload = Data("integrity-check-payload-0123456789".utf8)
        let corruptPayloadZip = dir.appendingPathComponent("corrupt_crc.zip")
        try writeRawLegacyZip(at: corruptPayloadZip, pathData: Data("check.txt".utf8), payload: payload)

        // Flip a payload byte while leaving headers intact to trigger a CRC failure during testArchive
        var bytes = try Data(contentsOf: corruptPayloadZip)
        let payloadByteOffset = 30 + "check.txt".utf8.count
        bytes[payloadByteOffset] ^= 0xFF
        try bytes.write(to: corruptPayloadZip)

        do {
            _ = try await engine.testArchive(at: corruptPayloadZip)
            Issue.record("Expected corruptArchive error for CRC-corrupted ZIP")
        } catch let error as Bento7zError {
            if case .corruptArchive = error {
                // Expected
            } else {
                Issue.record("Expected Bento7zError.corruptArchive, got \(error)")
            }
        }

        // Truncated ZIP archive must also fail with corruptArchive
        let truncatedZip = dir.appendingPathComponent("truncated.zip")
        try bytes.prefix(24).write(to: truncatedZip)
        do {
            _ = try await engine.testArchive(at: truncatedZip)
            Issue.record("Expected corruptArchive error for truncated ZIP")
        } catch let error as Bento7zError {
            if case .corruptArchive = error {
                // Expected
            } else {
                Issue.record("Expected Bento7zError.corruptArchive, got \(error)")
            }
        }
    }

    @Test func testArchive_encryptedArchives_enforcePasswordVerification() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let secretFile = dir.appendingPathComponent("secret.txt")
        try "classified-contents".write(to: secretFile, atomically: true, encoding: .utf8)

        for format in [ArchiveFormat.zip, .sevenZip] {
            let archiveURL = dir.appendingPathComponent("locked.\(format.fileExtension)")
            try await engine.create(
                from: [secretFile],
                to: archiveURL,
                settings: CompressionSettings(
                    format: format,
                    compressionLevel: .fast,
                    password: "correct-horse",
                    zipEncryptionMethod: .aes256
                )
            ) { _ in }

            do {
                _ = try await engine.testArchive(at: archiveURL, password: nil)
                Issue.record("Expected passwordRequired error for \(format.fileExtension)")
            } catch let error as Bento7zError {
                #expect(error == .passwordRequired)
            }

            do {
                _ = try await engine.testArchive(at: archiveURL, password: "wrong-password")
                Issue.record("Expected wrongPassword error for \(format.fileExtension)")
            } catch let error as Bento7zError {
                #expect(error == .wrongPassword)
            }

            let okResult = try await engine.testArchive(at: archiveURL, password: "correct-horse")
            #expect(okResult.itemsCount == 1)
        }
    }

    @Test func renameEntry_zip7zAndTar_renamesSingleFileAndNestedDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "alpha.txt": "alpha-body",
            "docs/sub/guide.md": "guide-body"
        ], in: srcDir)

        for format in [ArchiveFormat.zip, .sevenZip, .tar] {
            let archiveURL = dir.appendingPathComponent("rename.\(format.fileExtension)")
            try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: format)) { _ in }

            // Rename single top-level file
            try await engine.renameEntry(in: archiveURL, from: "alpha.txt", to: "omega.txt")
            var listed = try await engine.listArchive(
                in: archiveURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )
            let rootNamesAfterFileRename = Set(listed.entries.map(\.name))
            #expect(rootNamesAfterFileRename == ["docs", "omega.txt"])

            // Rename nested directory
            try await engine.renameEntry(in: archiveURL, from: "docs", to: "manual")
            listed = try await engine.listArchive(
                in: archiveURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )
            let rootNamesAfterDirRename = Set(listed.entries.map(\.name))
            #expect(rootNamesAfterDirRename == ["manual", "omega.txt"])

            let outDir = dir.appendingPathComponent("out_\(format.fileExtension)")
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outDir, password: nil) { _ in }
            #expect(try String(contentsOf: outDir.appendingPathComponent("omega.txt"), encoding: .utf8) == "alpha-body")
            #expect(try String(contentsOf: outDir.appendingPathComponent("manual/sub/guide.md"), encoding: .utf8) == "guide-body")
            #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("alpha.txt").path))
            #expect(!fm.fileExists(atPath: outDir.appendingPathComponent("docs").path))
        }
    }

    @Test func renameEntry_rejectsConflictsAndTraversalPaths() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "source.txt": "src",
            "existing.txt": "dst",
            "folder/item.txt": "nested"
        ], in: srcDir)

        let archiveURL = dir.appendingPathComponent("guards.zip")
        try await engine.create(from: inputs, to: archiveURL, settings: CompressionSettings(format: .zip)) { _ in }

        // Conflict rejection
        do {
            try await engine.renameEntry(in: archiveURL, from: "source.txt", to: "existing.txt")
            Issue.record("Expected conflict error when target already exists")
        } catch let error as Bento7zError {
            if case .conflict = error {
                // Expected
            } else {
                Issue.record("Expected Bento7zError.conflict, got \(error)")
            }
        }

        // Traversal path rejection (newPath and oldPath)
        for badPath in ["../escape.txt", "sub/../../escape.txt", "/abs/path.txt"] {
            do {
                try await engine.renameEntry(in: archiveURL, from: "source.txt", to: badPath)
                Issue.record("Expected INVALID_PATH for newPath '\(badPath)'")
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error {
                    #expect(code == "INVALID_PATH")
                } else {
                    Issue.record("Expected INVALID_PATH, got \(error)")
                }
            }

            do {
                try await engine.renameEntry(in: archiveURL, from: badPath, to: "clean.txt")
                Issue.record("Expected INVALID_PATH for oldPath '\(badPath)'")
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error {
                    #expect(code == "INVALID_PATH")
                } else {
                    Issue.record("Expected INVALID_PATH, got \(error)")
                }
            }
        }
    }

    @Test func addEntries_withTargetPrefix_placesItemsInSubfolderAndRejectsTraversal() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let initial = dir.appendingPathComponent("root.txt")
        let extra = dir.appendingPathComponent("extra.txt")
        try "root".write(to: initial, atomically: true, encoding: .utf8)
        try "extra-payload".write(to: extra, atomically: true, encoding: .utf8)

        for format in [ArchiveFormat.zip, .sevenZip] {
            let archiveURL = dir.appendingPathComponent("prefix.\(format.fileExtension)")
            try await engine.create(from: [initial], to: archiveURL, settings: CompressionSettings(format: format)) { _ in }

            try await engine.addEntries(
                to: archiveURL,
                from: [extra],
                targetPrefix: "assets/nested",
                password: nil
            ) { _ in }

            let listed = try await engine.listArchive(
                in: archiveURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )
            let assetsDir = try #require(listed.entries.first(where: { $0.name == "assets" && $0.isDirectory }))
            let nestedDir = try #require(assetsDir.children?.first(where: { $0.name == "nested" && $0.isDirectory }))
            let addedFile = try #require(nestedDir.children?.first(where: { $0.name == "extra.txt" }))
            #expect(addedFile.archiveRelativePath == "assets/nested/extra.txt")

            let outDir = dir.appendingPathComponent("out_prefix_\(format.fileExtension)")
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outDir, password: nil) { _ in }
            #expect(try String(contentsOf: outDir.appendingPathComponent("assets/nested/extra.txt"), encoding: .utf8) == "extra-payload")

            // Unsafe traversal prefix must be rejected before mutating the archive
            do {
                try await engine.addEntries(
                    to: archiveURL,
                    from: [extra],
                    targetPrefix: "../escape",
                    password: nil
                ) { _ in }
                Issue.record("Expected INVALID_PATH for traversal targetPrefix")
            } catch let error as Bento7zError {
                if case .operationFailed(_, let code) = error {
                    #expect(code == "INVALID_PATH")
                } else {
                    Issue.record("Expected INVALID_PATH, got \(error)")
                }
            }
        }
    }

    @Test func createFolder_insideWritableArchive_createsDirectoryEntries() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let seed = dir.appendingPathComponent("seed.txt")
        try "seed".write(to: seed, atomically: true, encoding: .utf8)

        for format in [ArchiveFormat.zip, .sevenZip] {
            let archiveURL = dir.appendingPathComponent("mkdir.\(format.fileExtension)")
            try await engine.create(from: [seed], to: archiveURL, settings: CompressionSettings(format: format)) { _ in }

            try await engine.createFolder(in: archiveURL, path: "docs/specs", password: nil, onProgress: nil)

            let listed = try await engine.listArchive(
                in: archiveURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )
            let docs = try #require(listed.entries.first(where: { $0.name == "docs" && $0.isDirectory }))
            let specs = try #require(docs.children?.first(where: { $0.name == "specs" && $0.isDirectory }))
            #expect(specs.isDirectory)
        }
    }

    @Test func manualEncodingOverride_decodesShiftJISAndGB18030OnListAndExtract() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // Shift-JIS bytes for "テスト/報告.txt":
        // テスト = 83 65 83 58 83 67, / = 2F, 報告 = 95 F1 8D 90, .txt = 2E 74 78 74
        let sjisPath = Data([0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x2F, 0x95, 0xF1, 0x8D, 0x90, 0x2E, 0x74, 0x78, 0x74])
        let sjisZip = dir.appendingPathComponent("manual_sjis.zip")
        try writeRawLegacyZip(at: sjisZip, pathData: sjisPath, payload: Data("sjis-manual-ok".utf8))

        let sjisListed = try await engine.listArchive(
            in: sjisZip,
            password: nil,
            encoding: FilenameEncodingOption.shiftJIS.iconvName,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        let sjisFolder = try #require(sjisListed.entries.first(where: { $0.name == "テスト" && $0.isDirectory }))
        let sjisFile = try #require(sjisFolder.children?.first(where: { $0.name == "報告.txt" }))
        #expect(sjisFile.archiveRelativePath == "テスト/報告.txt")

        let sjisOut = dir.appendingPathComponent("sjis_out")
        try await engine.extract(
            archiveURL: sjisZip,
            entries: nil,
            to: sjisOut,
            password: nil,
            encoding: FilenameEncodingOption.shiftJIS.iconvName
        ) { _ in }
        #expect(try String(contentsOf: sjisOut.appendingPathComponent("テスト/報告.txt"), encoding: .utf8) == "sjis-manual-ok")

        // GB18030 bytes for "目录/测试.txt": C4 BF C2 BC 2F B2 E2 CA D4 2E 74 78 74
        let gbPath = Data([0xC4, 0xBF, 0xC2, 0xBC, 0x2F, 0xB2, 0xE2, 0xCA, 0xD4, 0x2E, 0x74, 0x78, 0x74])
        let gbZip = dir.appendingPathComponent("manual_gb18030.zip")
        try writeRawLegacyZip(at: gbZip, pathData: gbPath, payload: Data("gb18030-manual-ok".utf8))

        let gbListed = try await engine.listArchive(
            in: gbZip,
            password: nil,
            encoding: FilenameEncodingOption.gb18030.iconvName,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        let gbFolder = try #require(gbListed.entries.first(where: { $0.name == "目录" && $0.isDirectory }))
        let gbFile = try #require(gbFolder.children?.first(where: { $0.name == "测试.txt" }))
        #expect(gbFile.archiveRelativePath == "目录/测试.txt")

        let gbOut = dir.appendingPathComponent("gb_out")
        try await engine.extract(
            archiveURL: gbZip,
            entries: nil,
            to: gbOut,
            password: nil,
            encoding: FilenameEncodingOption.gb18030.iconvName
        ) { _ in }
        #expect(try String(contentsOf: gbOut.appendingPathComponent("目录/测试.txt"), encoding: .utf8) == "gb18030-manual-ok")
    }

    @Test func listArchive_populatesNonZeroCRC32ViaBinaryClient() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("hello.txt")
        try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let zipURL = dir.appendingPathComponent("crc.zip")
        try await engine.create(from: [fileURL], to: zipURL, settings: CompressionSettings(format: .zip)) { _ in }

        let listed = try await engine.listArchive(in: zipURL)
        let entry = try #require(listed.entries.first(where: { $0.name == "hello.txt" }))
        let crc = try #require(entry.crc)
        #expect(crc != 0)
        // Standard IEEE CRC-32 of "hello world" is 0x0D4A1185
        #expect(crc == 0x0D4A_1185)
    }

    private func writeRawLegacyZipEntries(at url: URL, items: [(pathData: Data, payload: Data)]) throws {
        func appendU16(_ d: inout Data, _ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func appendU32(_ d: inout Data, _ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for b in data {
                var c = crc ^ UInt32(b)
                for _ in 0..<8 {
                    c = (c & 1) != 0 ? ((c >> 1) ^ 0xEDB8_8320) : (c >> 1)
                }
                crc = c
            }
            return crc ^ 0xFFFF_FFFF
        }

        var localHeaders = Data()
        var centralDirectory = Data()

        for item in items {
            let offset = UInt32(localHeaders.count)
            let crc = crc32(item.payload)

            var lh = Data()
            appendU32(&lh, 0x04034B50); appendU16(&lh, 20); appendU16(&lh, 0); appendU16(&lh, 0)
            appendU16(&lh, 0); appendU16(&lh, 0); appendU32(&lh, crc)
            appendU32(&lh, UInt32(item.payload.count)); appendU32(&lh, UInt32(item.payload.count))
            appendU16(&lh, UInt16(item.pathData.count)); appendU16(&lh, 0)
            lh.append(item.pathData); lh.append(item.payload)
            localHeaders.append(lh)

            var cd = Data()
            appendU32(&cd, 0x02014B50); appendU16(&cd, 20); appendU16(&cd, 20); appendU16(&cd, 0); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, crc)
            appendU32(&cd, UInt32(item.payload.count)); appendU32(&cd, UInt32(item.payload.count))
            appendU16(&cd, UInt16(item.pathData.count)); appendU16(&cd, 0); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, 0); appendU32(&cd, offset)
            cd.append(item.pathData)
            centralDirectory.append(cd)
        }

        var eocd = Data()
        appendU32(&eocd, 0x06054B50); appendU16(&eocd, 0); appendU16(&eocd, 0)
        appendU16(&eocd, UInt16(items.count)); appendU16(&eocd, UInt16(items.count))
        appendU32(&eocd, UInt32(centralDirectory.count)); appendU32(&eocd, UInt32(localHeaders.count)); appendU16(&eocd, 0)

        var zipBytes = Data()
        zipBytes.append(localHeaders); zipBytes.append(centralDirectory); zipBytes.append(eocd)
        try zipBytes.write(to: url)
    }

    @Test func renameEntryAndRemoveEntries_legacyCJKZip_operatesByDecodedUTF8Path() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // GBK bytes:
        // "目录/测试.txt" = C4 BF C2 BC 2F B2 E2 CA D4 2E 74 78 74
        // "中文/数据.txt" = D6 D0 CE C4 2F CA FD BE DD 2E 74 78 74
        let testGBK = Data([0xC4, 0xBF, 0xC2, 0xBC, 0x2F, 0xB2, 0xE2, 0xCA, 0xD4, 0x2E, 0x74, 0x78, 0x74])
        let dataGBK = Data([0xD6, 0xD0, 0xCE, 0xC4, 0x2F, 0xCA, 0xFD, 0xBE, 0xDD, 0x2E, 0x74, 0x78, 0x74])
        let zipURL = dir.appendingPathComponent("legacy_cjk_mutate.zip")
        try writeRawLegacyZipEntries(at: zipURL, items: [
            (testGBK, Data("cjk-test-payload".utf8)),
            (dataGBK, Data("cjk-data-payload".utf8))
        ])

        // Rename using the decoded UTF-8 path
        try await engine.renameEntry(in: zipURL, from: "目录/测试.txt", to: "目录/新名.txt")

        var listed = try await engine.listArchive(
            in: zipURL,
            password: nil,
            encoding: nil,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        let renamedDir = try #require(listed.entries.first(where: { $0.name == "目录" && $0.isDirectory }))
        #expect(renamedDir.children?.map(\.name) == ["新名.txt"])
        let dataDir = try #require(listed.entries.first(where: { $0.name == "中文" && $0.isDirectory }))
        let dataEntry = try #require(dataDir.children?.first(where: { $0.name == "数据.txt" }))

        let outDir = dir.appendingPathComponent("out_cjk")
        try await engine.extract(archiveURL: zipURL, entries: nil, to: outDir, password: nil) { _ in }
        #expect(try String(contentsOf: outDir.appendingPathComponent("目录/新名.txt"), encoding: .utf8) == "cjk-test-payload")
        #expect(try String(contentsOf: outDir.appendingPathComponent("中文/数据.txt"), encoding: .utf8) == "cjk-data-payload")

        // Remove the remaining legacy GBK entry using its decoded UTF-8 FileEntry
        try await engine.removeEntries(from: zipURL, entries: [dataEntry])

        listed = try await engine.listArchive(
            in: zipURL,
            password: nil,
            encoding: nil,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        #expect(listed.entries.map(\.name) == ["目录"])
        #expect(listed.entries.first?.children?.map(\.name) == ["新名.txt"])
    }

    @Test func renameEntry_compoundTarGzAndSolid7z_rejectsConflictsWithConflictError() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let inputs = try makeFiles([
            "source.txt": "source-data",
            "existing.txt": "existing-data"
        ], in: srcDir)

        for format in [ArchiveFormat.tarGz, .sevenZip] {
            let archiveURL = dir.appendingPathComponent("conflict.\(format.fileExtension)")
            try await engine.create(
                from: inputs,
                to: archiveURL,
                settings: CompressionSettings(format: format, compressionLevel: .best)
            ) { _ in }

            do {
                try await engine.renameEntry(in: archiveURL, from: "source.txt", to: "existing.txt")
                Issue.record("Expected Bento7zError.conflict for \(format.fileExtension)")
            } catch let error as Bento7zError {
                if case .conflict = error {
                    // Expected
                } else {
                    Issue.record("Expected Bento7zError.conflict for \(format.fileExtension), got \(error)")
                }
            }

            let outDir = dir.appendingPathComponent("verify_\(format.fileExtension)")
            try await engine.extract(archiveURL: archiveURL, entries: nil, to: outDir, password: nil) { _ in }
            #expect(try String(contentsOf: outDir.appendingPathComponent("source.txt"), encoding: .utf8) == "source-data")
            #expect(try String(contentsOf: outDir.appendingPathComponent("existing.txt"), encoding: .utf8) == "existing-data")
        }
    }
}
