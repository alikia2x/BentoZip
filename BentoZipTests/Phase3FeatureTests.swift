import Foundation
import os
import Testing
import BentoZipCore

// MARK: - Rare & Phase 3 Format Detection Tests

@Suite(.serialized)
struct Phase3FormatDetectorTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("Phase3FormatTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func detectReadableFormat_phase3ExtensionsAndCompoundFormats() {
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "rootfs.squashfs")) == .squashfs)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "rootfs.sfs")) == .squashfs)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "disk.vmdk")) == .vmdk)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "manual.chm")) == .chm)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "old.arj")) == .arj)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "blob.lz4")) == .lz4)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "bundle.tar.lz4")) == .tarLz4)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "bundle.tlz4")) == .tarLz4)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "web.br")) == .brotli)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "book.epub")) == .epub)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "disk.dmg")) == .dmg)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "file.zst")) == .zst)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "pack.tar.zst")) == .tarZst)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "pack.tzst")) == .tarZst)

        // Read-only vs writable checks
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "book.epub")) == nil)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "book.epub"))?.isReadOnly == true)
        #expect(FormatDetector.detectReadableFormat(of: URL(fileURLWithPath: "book.epub"))?.bento7zFormatName == "zip")
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "pack.tar.zst")) == .tarZstd)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "disk.dmg")) == nil)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "bundle.tar.lz4")) == nil)
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "web.br")) == nil)
    }

    @Test func detectReadableFormat_phase3MagicBytesAndEpub() throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let magicCases: [(String, [UInt8], ReadableArchiveFormat)] = [
            ("squashfs_le.bin", [0x68, 0x73, 0x71, 0x73, 0x00, 0x00, 0x00, 0x00], .squashfs),
            ("squashfs_be.bin", [0x73, 0x71, 0x73, 0x68, 0x00, 0x00, 0x00, 0x00], .squashfs),
            ("vmdk.bin", [0x4B, 0x44, 0x4D, 0x56, 0x01, 0x00, 0x00, 0x00], .vmdk),
            ("chm.bin", [0x49, 0x54, 0x53, 0x46, 0x03, 0x00, 0x00, 0x00], .chm),
            ("arj.bin", [0x60, 0xEA, 0x27, 0x00, 0x1E, 0x00, 0x00, 0x00], .arj),
            ("lz4.bin", [0x04, 0x22, 0x4D, 0x18, 0x64, 0x40, 0xA7, 0x00], .lz4),
            ("zst.bin", [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x01, 0x00], .zst),
            ("novel.epub", [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00], .epub)
        ]

        for (fileName, bytes, expected) in magicCases {
            let fileURL = dir.appendingPathComponent(fileName)
            try Data(bytes).write(to: fileURL)
            #expect(FormatDetector.detectReadableFormat(of: fileURL) == expected)
            #expect(FormatDetector.isArchiveFile(fileURL))
        }
    }
}

// MARK: - DMG, Zstd & Rare CLI Format Round-Trip Tests

@Suite(.serialized)
struct Phase3ArchiveEngineTests {
    private let engine = Bento7zEngine()
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("Phase3EngineTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func findExtractedFile(named fileName: String, under root: URL) -> URL? {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == fileName {
            return candidate
        }
        return nil
    }

    private func runTool(executablePath: String, arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let stderr = Pipe()
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw Bento7zError.processError("\(executablePath) exited \(process.terminationStatus): \(msg)")
            }
        }.value
    }

    @Test func dmg_createViaDiskImageAndBento7zEngine_listsAndExtractsCleanly() async throws {
        guard fm.isExecutableFile(atPath: DiskImageEngine.hdiutilPath) else { return }

        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcFolder = dir.appendingPathComponent("ReleaseApp")
        let subFolder = srcFolder.appendingPathComponent("Config")
        try fm.createDirectory(at: subFolder, withIntermediateDirectories: true)
        try "hello dmg payload".write(to: srcFolder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "{\"ok\":true}".write(to: subFolder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let dmgDirect = dir.appendingPathComponent("DirectImage.dmg")
        let progressLock = OSAllocatedUnfairLock(initialState: 0.0)
        try await DiskImageEngine().create(
            from: [srcFolder],
            to: dmgDirect,
            settings: CompressionSettings(format: .dmg)
        ) { update in
            progressLock.withLock { $0 = max($0, update.fractionCompleted) }
        }
        #expect(fm.fileExists(atPath: dmgDirect.path))
        #expect(progressLock.withLock { $0 } == 1.0)

        let dmgViaEngine = dir.appendingPathComponent("EngineImage.dmg")
        try await engine.create(
            from: [srcFolder],
            to: dmgViaEngine,
            settings: CompressionSettings(format: .dmg)
        ) { _ in }
        #expect(fm.fileExists(atPath: dmgViaEngine.path))

        for dmgURL in [dmgDirect, dmgViaEngine] {
            let listed = try await engine.listArchive(
                in: dmgURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )
            let hfsEntry = try #require(listed.entries.first(where: { $0.name.lowercased().hasSuffix(".hfs") }))

            let outDir = dir.appendingPathComponent("out_\(dmgURL.deletingPathExtension().lastPathComponent)")
            try await engine.extract(archiveURL: dmgURL, entries: nil, to: outDir, password: nil) { _ in }

            let hfsURL = outDir.appendingPathComponent(hfsEntry.name)
            #expect(fm.fileExists(atPath: hfsURL.path))

            let hfsListed = try await engine.listArchive(
                in: hfsURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: true,
                onProgress: nil
            )
            #expect(!hfsListed.entries.isEmpty)

            let hfsOutDir = dir.appendingPathComponent("hfs_out_\(dmgURL.deletingPathExtension().lastPathComponent)")
            try await engine.extract(archiveURL: hfsURL, entries: nil, to: hfsOutDir, password: nil) { _ in }

            let extractedReadme = try #require(findExtractedFile(named: "readme.txt", under: hfsOutDir))
            let extractedSettings = try #require(findExtractedFile(named: "settings.json", under: hfsOutDir))
            #expect(try String(contentsOf: extractedReadme, encoding: .utf8) == "hello dmg payload")
            #expect(try String(contentsOf: extractedSettings, encoding: .utf8) == "{\"ok\":true}")
        }
    }

    @Test func zstdAndTarZstd_createListAndExtractRoundTrip() async throws {
        guard ZstdEngine.findZstdBinary() != nil else { return }

        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // 1. Single-file .zst round-trip
        let singleSrc = dir.appendingPathComponent("note.txt")
        try "zstd single-file payload".write(to: singleSrc, atomically: true, encoding: .utf8)
        let zstURL = dir.appendingPathComponent("note.txt.zst")

        try await engine.create(
            from: [singleSrc],
            to: zstURL,
            settings: CompressionSettings(format: .zstd, compressionLevel: .normal)
        ) { _ in }
        #expect(fm.fileExists(atPath: zstURL.path))

        let zstEntries = try await engine.listEntries(in: zstURL)
        #expect(!zstEntries.isEmpty)

        let zstOut = dir.appendingPathComponent("zst_out")
        try await engine.extract(archiveURL: zstURL, entries: nil, to: zstOut, password: nil) { _ in }
        let extractedSingle = try #require(findExtractedFile(named: "note.txt", under: zstOut))
        #expect(try String(contentsOf: extractedSingle, encoding: .utf8) == "zstd single-file payload")

        // 2. Multi-file .tar.zst round-trip
        let bundleDir = dir.appendingPathComponent("Bundle")
        let nestedDir = bundleDir.appendingPathComponent("Nested")
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let topFile = dir.appendingPathComponent("top.txt")
        try "top-content".write(to: topFile, atomically: true, encoding: .utf8)
        try "nested-content".write(to: nestedDir.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)

        let tarZstURL = dir.appendingPathComponent("bundle.tar.zst")
        try await engine.create(
            from: [topFile, bundleDir],
            to: tarZstURL,
            settings: CompressionSettings(format: .tarZstd, compressionLevel: .fast)
        ) { _ in }
        #expect(fm.fileExists(atPath: tarZstURL.path))

        let tarZstListed = try await engine.listArchive(
            in: tarZstURL,
            password: nil,
            encoding: nil,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        #expect(Set(tarZstListed.entries.map(\.name)) == ["Bundle", "top.txt"])

        let tarZstOut = dir.appendingPathComponent("tar_zst_out")
        try await engine.extract(archiveURL: tarZstURL, entries: nil, to: tarZstOut, password: nil) { _ in }
        #expect(try String(contentsOf: tarZstOut.appendingPathComponent("top.txt"), encoding: .utf8) == "top-content")
        #expect(try String(contentsOf: tarZstOut.appendingPathComponent("Bundle/Nested/inner.txt"), encoding: .utf8) == "nested-content")
    }

    @Test func lz4AndTarLz4_listAndExtractViaFallbackWhenAvailable() async throws {
        let lz4Candidates = ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/usr/bin/lz4"]
        guard let lz4Bin = lz4Candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return
        }

        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // 1. Single-file .lz4
        let rawFile = dir.appendingPathComponent("sample.txt")
        try "lz4-single-payload".write(to: rawFile, atomically: true, encoding: .utf8)
        let lz4URL = dir.appendingPathComponent("sample.txt.lz4")
        try await runTool(executablePath: lz4Bin, arguments: ["-f", "-q", rawFile.path, lz4URL.path])

        let lz4Listed = try await engine.listEntries(in: lz4URL)
        #expect(lz4Listed.contains(where: { $0.name == "sample.txt" }))

        let lz4Out = dir.appendingPathComponent("lz4_out")
        try await engine.extract(archiveURL: lz4URL, entries: nil, to: lz4Out, password: nil) { _ in }
        let extractedSingle = try #require(findExtractedFile(named: "sample.txt", under: lz4Out))
        #expect(try String(contentsOf: extractedSingle, encoding: .utf8) == "lz4-single-payload")

        // 2. Compound .tar.lz4
        let tarSrcDir = dir.appendingPathComponent("tar_src")
        let subDir = tarSrcDir.appendingPathComponent("sub")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let f1 = tarSrcDir.appendingPathComponent("one.txt")
        let f2 = subDir.appendingPathComponent("two.txt")
        try "tar-lz4-one".write(to: f1, atomically: true, encoding: .utf8)
        try "tar-lz4-two".write(to: f2, atomically: true, encoding: .utf8)

        let rawTarURL = dir.appendingPathComponent("payload.tar")
        try await engine.create(from: [f1, subDir], to: rawTarURL, settings: CompressionSettings(format: .tar)) { _ in }
        let tarLz4URL = dir.appendingPathComponent("payload.tar.lz4")
        try await runTool(executablePath: lz4Bin, arguments: ["-f", "-q", rawTarURL.path, tarLz4URL.path])

        let tarLz4Listed = try await engine.listArchive(
            in: tarLz4URL,
            password: nil,
            encoding: nil,
            unwrapSingleTopDirectory: false,
            onProgress: nil
        )
        #expect(Set(tarLz4Listed.entries.map(\.name)) == ["one.txt", "sub"])

        let tarLz4Out = dir.appendingPathComponent("tar_lz4_out")
        try await engine.extract(archiveURL: tarLz4URL, entries: nil, to: tarLz4Out, password: nil) { _ in }
        #expect(try String(contentsOf: tarLz4Out.appendingPathComponent("one.txt"), encoding: .utf8) == "tar-lz4-one")
        #expect(try String(contentsOf: tarLz4Out.appendingPathComponent("sub/two.txt"), encoding: .utf8) == "tar-lz4-two")
    }

    @Test func brotli_listAndExtractViaFallbackWhenAvailable() async throws {
        let brCandidates = ["/opt/homebrew/bin/brotli", "/usr/local/bin/brotli", "/usr/bin/brotli"]
        guard let brBin = brCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            return
        }

        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let rawFile = dir.appendingPathComponent("readme.txt")
        try "brotli-stream-payload".write(to: rawFile, atomically: true, encoding: .utf8)
        let brURL = dir.appendingPathComponent("readme.txt.br")
        try await runTool(executablePath: brBin, arguments: ["-f", "-o", brURL.path, rawFile.path])

        let listed = try await engine.listEntries(in: brURL)
        #expect(listed.contains(where: { $0.name == "readme.txt" }))

        let brOut = dir.appendingPathComponent("br_out")
        try await engine.extract(archiveURL: brURL, entries: nil, to: brOut, password: nil) { _ in }
        let extracted = try #require(findExtractedFile(named: "readme.txt", under: brOut))
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "brotli-stream-payload")
    }
}

// MARK: - UpdateChecker & SemVer Tests

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerLock = OSAllocatedUnfairLock<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handlerLock.withLock { $0 }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct Phase3UpdateCheckerTests {
    private func makeMockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.handlerLock.withLock { $0 = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func semVer_parsingAndComparisonOrder() throws {
        let parsed = try #require(SemVer(string: "v1.2.3"))
        #expect(parsed.major == 1)
        #expect(parsed.minor == 2)
        #expect(parsed.patch == 3)
        #expect(parsed.prerelease == nil)
        #expect(parsed.description == "1.2.3")

        let beta = try #require(SemVer(string: "1.2.3-beta.1+build.42"))
        #expect(beta.major == 1)
        #expect(beta.minor == 2)
        #expect(beta.patch == 3)
        #expect(beta.prerelease == "beta.1")

        #expect(try #require(SemVer(string: "1.2.10")) > #require(SemVer(string: "1.2.2")))
        #expect(try #require(SemVer(string: "1.0.0-alpha")) < #require(SemVer(string: "1.0.0-alpha.1")))
        #expect(try #require(SemVer(string: "1.0.0-alpha.1")) < #require(SemVer(string: "1.0.0-beta")))
        #expect(try #require(SemVer(string: "1.0.0-beta")) < #require(SemVer(string: "1.0.0")))
        #expect(try #require(SemVer(string: "1.0.0")) < #require(SemVer(string: "1.0.1")))

        #expect(SemVer(string: "") == nil)
        #expect(SemVer(string: "not-a-version") == nil)
        #expect(SemVer(string: "1.2.3.4") == nil)
    }

    @Test func parseRelease_decodesGitHubJSONAndPrefersDmgOverZip() throws {
        let jsonDmgAndZip = """
        {
          "tag_name": "v2.4.0",
          "name": "BentoZip 2.4.0",
          "body": "Release notes here",
          "html_url": "https://github.com/alikia/BentoZip/releases/tag/v2.4.0",
          "published_at": "2026-11-20T10:30:00Z",
          "assets": [
            {
              "name": "BentoZip-2.4.0.zip",
              "browser_download_url": "https://github.com/alikia/BentoZip/releases/download/v2.4.0/BentoZip-2.4.0.zip"
            },
            {
              "name": "BentoZip-2.4.0.dmg",
              "browser_download_url": "https://github.com/alikia/BentoZip/releases/download/v2.4.0/BentoZip-2.4.0.dmg"
            }
          ]
        }
        """

        let release = try UpdateChecker.parseRelease(from: Data(jsonDmgAndZip.utf8))
        #expect(release.tagName == "v2.4.0")
        #expect(release.name == "BentoZip 2.4.0")
        #expect(release.body == "Release notes here")
        #expect(release.htmlURL.absoluteString == "https://github.com/alikia/BentoZip/releases/tag/v2.4.0")
        #expect(release.publishedAt != nil)
        #expect(release.downloadURL?.lastPathComponent == "BentoZip-2.4.0.dmg")

        let jsonZipOnly = """
        {
          "tag_name": "v2.4.1",
          "html_url": "https://github.com/alikia/BentoZip/releases/tag/v2.4.1",
          "assets": [
            {
              "name": "BentoZip-2.4.1.zip",
              "browser_download_url": "https://github.com/alikia/BentoZip/releases/download/v2.4.1/BentoZip-2.4.1.zip"
            }
          ]
        }
        """

        let zipRelease = try UpdateChecker.parseRelease(from: Data(jsonZipOnly.utf8))
        #expect(zipRelease.name == "v2.4.1")
        #expect(zipRelease.downloadURL?.lastPathComponent == "BentoZip-2.4.1.zip")
    }

    @Test func checkForUpdates_returnsUpdateAvailableUpToDateAndFailed() async throws {
        defer { MockURLProtocol.handlerLock.withLock { $0 = nil } }

        let endpoint = URL(string: "https://example.test/releases/latest")!
        let payload = """
        {
          "tag_name": "v1.5.0",
          "name": "1.5.0",
          "body": "Phase 3 release",
          "html_url": "https://github.com/alikia/BentoZip/releases/tag/v1.5.0",
          "assets": [
            {
              "name": "BentoZip-1.5.0.dmg",
              "browser_download_url": "https://github.com/alikia/BentoZip/releases/download/v1.5.0/BentoZip-1.5.0.dmg"
            }
          ]
        }
        """

        // 1. Newer release available
        let sessionAvailable = makeMockSession { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(payload.utf8))
        }
        let checkerNew = UpdateChecker(endpointURL: endpoint, currentVersion: "1.4.2", session: sessionAvailable)
        let statusNew = await checkerNew.checkForUpdates()
        if case .updateAvailable(let info) = statusNew {
            #expect(info.tagName == "v1.5.0")
            #expect(info.downloadURL?.lastPathComponent == "BentoZip-1.5.0.dmg")
        } else {
            Issue.record("Expected .updateAvailable, got \(statusNew)")
        }
        #expect(checkerNew.lastCheckedAt != nil)

        // 2. Already on latest version
        let checkerCurrent = UpdateChecker(endpointURL: endpoint, currentVersion: "1.5.0", session: sessionAvailable)
        let statusCurrent = await checkerCurrent.checkForUpdates()
        #expect(statusCurrent == .upToDate(currentVersion: "1.5.0"))

        // 3. Server error returns .failed
        let sessionError = makeMockSession { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let checkerError = UpdateChecker(endpointURL: endpoint, currentVersion: "1.5.0", session: sessionError)
        let statusError = await checkerError.checkForUpdates()
        if case .failed(let message) = statusError {
            #expect(message.contains("503"))
        } else {
            Issue.record("Expected .failed, got \(statusError)")
        }
    }
}

// MARK: - CLIToolInstaller Tests

@Suite(.serialized)
struct Phase3CLIToolInstallerTests {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("Phase3CLITest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func generateWrapperScript_containsAllCommandsAndEscapedAppBundlePath() {
        let appPath = "/Applications/My 'BentoZip' App/BentoZip.app"
        let script = CLIToolInstaller.generateWrapperScript(appBundlePath: appPath)

        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("# BentoZip CLI wrapper"))
        #expect(script.contains("APP_BUNDLE='/Applications/My '\\''BentoZip'\\'' App/BentoZip.app'"))
        for command in ["open", "list", "extract", "compress", "test"] {
            #expect(script.contains(command))
        }
    }

    @Test func installAndUninstall_inIsolatedTempDirectory_updatesScriptAndPermissions() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let installPath = dir.appendingPathComponent("bin/bentozip").path
        let fakeAppURL = dir.appendingPathComponent("BentoZip.app", isDirectory: true)
        let installer = CLIToolInstaller(installPath: installPath, appBundleURL: fakeAppURL)

        #expect(!installer.isInstalled)

        try await installer.install(allowAdminPrompt: false)
        #expect(installer.isInstalled)
        #expect(fm.isExecutableFile(atPath: installPath))

        let attrs = try fm.attributesOfItem(atPath: installPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o755)

        let installedScript = try String(contentsOfFile: installPath, encoding: .utf8)
        #expect(installedScript.contains(fakeAppURL.path))

        try await installer.uninstall(allowAdminPrompt: false)
        #expect(!installer.isInstalled)
        #expect(!fm.fileExists(atPath: installPath))

        // Unwritable path with allowAdminPrompt: false must throw permissionDenied
        let restrictedInstaller = CLIToolInstaller(
            installPath: "/System/Library/bentozip_test_\(UUID().uuidString)",
            appBundleURL: fakeAppURL
        )
        do {
            try await restrictedInstaller.install(allowAdminPrompt: false)
            Issue.record("Expected permissionDenied when writing to restricted system directory")
        } catch let error as CLIToolInstallerError {
            if case .permissionDenied = error {
                // Expected
            } else {
                Issue.record("Expected permissionDenied, got \(error)")
            }
        }
    }
}
