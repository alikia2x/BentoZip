import Foundation
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
}
