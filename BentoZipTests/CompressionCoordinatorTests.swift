import Foundation
import Testing
import BentoZipCore

@Suite(.serialized) @MainActor
struct CompressionCoordinatorTests {
    let coordinator = CompressionCoordinator()
    let fm = FileManager.default

    // MARK: - browseArchive

    @Test
    func browseArchive_listEntries_populatesAppState() async throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("CCBrowseTest_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fileURL = tmp.appendingPathComponent("data.txt")
        try "test content".write(to: fileURL, atomically: true, encoding: .utf8)

        let engine = Bento7zEngine()
        let archiveURL = tmp.appendingPathComponent("browse.zip")
        try await engine.create(from: [fileURL], to: archiveURL,
            settings: CompressionSettings(), progress: { _ in })

        let appState = AppState()
        await coordinator.browseArchive(at: archiveURL, appState: appState)

        #expect(appState.mode == .browseArchive)
        #expect(!appState.fileEntries.isEmpty)
    }

    @Test
    func browseArchive_nonexistent_setsError() async throws {
        let appState = AppState()
        let nonexistent = URL(fileURLWithPath: "/tmp/__no_such_browse_xyz_999.zip")
        await coordinator.browseArchive(at: nonexistent, appState: appState)
        #expect(appState.lastError != nil)
    }

    // MARK: - FormatDetector

    @Test func detectFormat_zipExtension() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.zip")) == .zip)
    }

    @Test func detectFormat_7zExtension() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.7z")) == .sevenZip)
    }

    @Test func detectFormat_tarGzExtension() {
        // tar.gz is now handled by bento7z auto-detection, mapped to sevenZip
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tar.gz")) == .sevenZip)
    }

    @Test func detectFormat_tgzExtension() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.tgz")) == .sevenZip)
    }

    @Test func detectFormat_gzExtension() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "test.gz")) == .sevenZip)
    }

    @Test func detectFormat_unknown() {
        #expect(FormatDetector.detectFormat(of: URL(fileURLWithPath: "readme.txt")) == nil)
    }

    @Test func detectFormat_zipMagicBytes() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("detect_\(UUID().uuidString)"); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        try Data(bytes).write(to: file)

        #expect(FormatDetector.detectFormat(of: file) == .zip)
    }

    @Test func detectFormat_7zMagicBytes() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("detect_\(UUID().uuidString)"); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        let bytes: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF]
        try Data(bytes).write(to: file)

        #expect(FormatDetector.detectFormat(of: file) == .sevenZip)
    }

    @Test func detectFormat_gzipMagicBytes() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("detect_\(UUID().uuidString)"); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        let bytes: [UInt8] = [0x1F, 0x8B]
        try Data(bytes).write(to: file)

        // gzip magic now maps to sevenZip (bento7z handles it)
        #expect(FormatDetector.detectFormat(of: file) == .sevenZip)
    }

    @Test func detectFormat_emptyFile() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("detect_\(UUID().uuidString)"); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        #expect(FormatDetector.detectFormat(of: file) == nil)
    }

    @Test func detectFormat_extensionWinsOverMagic() throws {
        let tmp = fm.temporaryDirectory.appendingPathComponent("detect_\(UUID().uuidString)"); try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("test.zip")
        let bytes: [UInt8] = [0x1F, 0x8B]
        try Data(bytes).write(to: file)

        #expect(FormatDetector.detectFormat(of: file) == .zip)
    }

    @Test func isArchiveFile_true() {
        #expect(FormatDetector.isArchiveFile(URL(fileURLWithPath: "test.zip")))
    }

    @Test func isArchiveFile_false() {
        #expect(!FormatDetector.isArchiveFile(URL(fileURLWithPath: "readme.txt")))
    }
}
