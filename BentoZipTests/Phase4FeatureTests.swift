import Foundation
import Testing
@testable import BentoZipCore

@Suite(.serialized)
struct ArchiveQuickPreviewFormatterTests {
    private let engine = Bento7zEngine()
    private let fm = FileManager.default
    private let formatter = ArchiveQuickPreviewFormatter.shared

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("Phase4PreviewTest_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func escapeHTML_escapesAllDangerousCharacters() {
        let raw = #"<script>alert("xss" & 'inject')</script>"#
        let expected = "&lt;script&gt;alert(&quot;xss&quot; &amp; &#39;inject&#39;)&lt;/script&gt;"
        #expect(ArchiveQuickPreviewFormatter.escapeHTML(raw) == expected)
        #expect(formatter.escapeHTML(raw) == expected)
        #expect(ArchiveQuickPreviewFormatter.escapeHTML("plain-text_123.txt") == "plain-text_123.txt")
    }

    @Test func renderHTMLPreview_realZip_escapesFilenamesAndShowsStats() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let docsDir = srcDir.appendingPathComponent("docs")
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let normalFile = docsDir.appendingPathComponent("readme.txt")
        let htmlNamedFile = srcDir.appendingPathComponent(#"<b title="x">"hello"&'world'.txt"#)
        try "hello preview".write(to: normalFile, atomically: true, encoding: .utf8)
        try "escaped payload".write(to: htmlNamedFile, atomically: true, encoding: .utf8)

        let zipURL = dir.appendingPathComponent("sample.zip")
        try await engine.create(
            from: [docsDir, htmlNamedFile],
            to: zipURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let preview = await formatter.renderHTMLPreview(for: zipURL)
        #expect(preview.formatName == "ZIP")
        #expect(preview.entryCount >= 2)
        #expect(preview.html.contains("@media (prefers-color-scheme: dark)"))
        #expect(preview.html.contains("badge-format"))
        #expect(preview.html.contains("docs/readme.txt"))
        #expect(preview.html.contains("&lt;b title=&quot;x&quot;&gt;&quot;hello&quot;&amp;&#39;world&#39;.txt"))
        #expect(!preview.html.contains(#"<b title="x">"#))
    }

    @Test func renderHTMLPreview_respectsMaxEntriesTruncation() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("many")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var inputs: [URL] = []
        for idx in 1...12 {
            let name = String(format: "item_%02d.txt", idx)
            let url = srcDir.appendingPathComponent(name)
            try "content \(idx)".write(to: url, atomically: true, encoding: .utf8)
            inputs.append(url)
        }

        let zipURL = dir.appendingPathComponent("many.zip")
        try await engine.create(
            from: inputs,
            to: zipURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let preview = await formatter.renderHTMLPreview(for: zipURL, maxEntries: 5)
        #expect(preview.formatName == "ZIP")
        #expect(preview.entryCount == 12)
        #expect(preview.html.contains("Showing first 5 of 12 items."))
        #expect(preview.html.contains("item_01.txt"))
        #expect(!preview.html.contains("item_12.txt"))
    }

    @Test func renderHTMLPreview_tarGz_andSevenZip_workCleanly() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let subDir = srcDir.appendingPathComponent("sub")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let alpha = srcDir.appendingPathComponent("alpha.txt")
        let beta = subDir.appendingPathComponent("beta.md")
        try "alpha-body".write(to: alpha, atomically: true, encoding: .utf8)
        try "# Beta".write(to: beta, atomically: true, encoding: .utf8)

        let tarGzURL = dir.appendingPathComponent("archive.tar.gz")
        try await engine.create(
            from: [alpha, subDir],
            to: tarGzURL,
            settings: CompressionSettings(format: .tarGz)
        ) { _ in }

        let tarGzPreview = await formatter.renderHTMLPreview(for: tarGzURL)
        #expect(tarGzPreview.formatName == "TAR.GZ")
        #expect(tarGzPreview.entryCount >= 2)
        #expect(tarGzPreview.html.contains("alpha.txt"))
        #expect(tarGzPreview.html.contains("sub/beta.md"))

        let sevenZipURL = dir.appendingPathComponent("archive.7z")
        try await engine.create(
            from: [alpha, subDir],
            to: sevenZipURL,
            settings: CompressionSettings(format: .sevenZip)
        ) { _ in }

        let sevenZipPreview = await formatter.renderHTMLPreview(for: sevenZipURL)
        #expect(sevenZipPreview.formatName == "7z")
        #expect(sevenZipPreview.entryCount >= 2)
        #expect(sevenZipPreview.html.contains("alpha.txt"))
        #expect(sevenZipPreview.html.contains("sub/beta.md"))
    }

    @Test func renderHTMLPreview_missingFile_fallsBackGracefully() async {
        let missingURL = fm.temporaryDirectory.appendingPathComponent("nonexistent_\(UUID().uuidString).zip")
        let preview = await formatter.renderHTMLPreview(for: missingURL)

        #expect(preview.formatName == "ZIP")
        #expect(preview.entryCount == 0)
        #expect(preview.html.contains("No Previewable Entries"))
    }

    @Test func extractSpotlightMetadata_populatesSearchableEntriesAndDescription() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        let srcDir = dir.appendingPathComponent("src")
        let docsDir = srcDir.appendingPathComponent("docs")
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let guide = docsDir.appendingPathComponent("guide.md")
        let logo = srcDir.appendingPathComponent("logo.png")
        try "# User Guide".write(to: guide, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: logo)

        let zipURL = dir.appendingPathComponent("spotlight.zip")
        try await engine.create(
            from: [docsDir, logo],
            to: zipURL,
            settings: CompressionSettings(format: .zip)
        ) { _ in }

        let metadata = await formatter.extractSpotlightMetadata(for: zipURL)
        #expect(metadata.formatName == "ZIP")
        #expect(metadata.itemCount >= 2)
        #expect(metadata.searchableText.contains("docs/guide.md"))
        #expect(metadata.searchableText.contains("guide.md"))
        #expect(metadata.searchableText.contains("logo.png"))
        #expect(metadata.searchableText.utf8.count <= 128 * 1024)
        #expect(metadata.descriptionText == "ZIP archive containing \(metadata.itemCount) items")
    }

    @Test func renderHTMLPreview_andEscapeHTML_handleExtremeAndOverflowInputsSafely() async throws {
        let dir = try makeTempDir()
        defer { try? fm.removeItem(at: dir) }

        // 1. Large HTML-escaping input does not blow stack or leave unescaped tokens
        let unit = #"<div data-x="1&2">'test'</div>"#
        let largeInput = String(repeating: unit, count: 2_000)
        let escapedLarge = ArchiveQuickPreviewFormatter.escapeHTML(largeInput)
        #expect(!escapedLarge.contains("<div"))
        #expect(escapedLarge.contains("&lt;div data-x=&quot;1&amp;2&quot;&gt;&#39;test&#39;&lt;/div&gt;"))

        // 2. Malformed TAR with GNU base-256 size overflowing Int64 does not trap
        var tarBlock = [UInt8](repeating: 0, count: 512)
        let nameBytes = Array("huge.bin".utf8)
        tarBlock.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        // GNU base-256 oversized value: 0x80 followed by all 0xFF (> Int64.max)
        tarBlock[124] = 0x80
        for idx in 125..<136 {
            tarBlock[idx] = 0xFF
        }
        tarBlock[156] = UInt8(ascii: "0")
        let ustar = Array("ustar".utf8)
        tarBlock.replaceSubrange(257..<(257 + ustar.count), with: ustar)
        // Compute valid TAR header checksum (field 148..<156 filled with spaces during sum)
        for idx in 148..<156 { tarBlock[idx] = 0x20 }
        let checksum = tarBlock.reduce(0) { $0 + Int($1) }
        let oct = Array(String(format: "%06o\0 ", checksum).utf8)
        tarBlock.replaceSubrange(148..<(148 + oct.count), with: oct)

        var tarData = Data(tarBlock)
        tarData.append(Data(count: 1024))
        let malformedTarURL = dir.appendingPathComponent("overflow.tar")
        try tarData.write(to: malformedTarURL)

        let tarPreview = await formatter.renderHTMLPreview(for: malformedTarURL)
        #expect(tarPreview.formatName == "TAR")
        #expect(!tarPreview.html.isEmpty)

        // 3. Synthetic ZIP with multiple huge Zip64-sized entries (each Int64.max / 2 + 100) must not trap on totals
        func appendU16(_ d: inout Data, _ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func appendU32(_ d: inout Data, _ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
        func appendU64(_ d: inout Data, _ v: UInt64) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }

        var cd = Data()
        let hugeSize = UInt64(Int64.max / 2) + 1024
        for idx in 1...3 {
            let entryName = Data("giant_\(idx).bin".utf8)
            var extra = Data()
            appendU16(&extra, 0x0001) // Zip64 extra field tag
            appendU16(&extra, 16)
            appendU64(&extra, hugeSize)
            appendU64(&extra, 128)

            appendU32(&cd, 0x02014B50)
            appendU16(&cd, 45); appendU16(&cd, 45); appendU16(&cd, 0); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, 0)
            appendU32(&cd, 0xFFFF_FFFF); appendU32(&cd, 0xFFFF_FFFF)
            appendU16(&cd, UInt16(entryName.count)); appendU16(&cd, UInt16(extra.count)); appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0); appendU32(&cd, 0); appendU32(&cd, 0)
            cd.append(entryName)
            cd.append(extra)
        }

        var eocd = Data()
        appendU32(&eocd, 0x06054B50); appendU16(&eocd, 0); appendU16(&eocd, 0)
        appendU16(&eocd, 3); appendU16(&eocd, 3)
        appendU32(&eocd, UInt32(cd.count)); appendU32(&eocd, 0); appendU16(&eocd, 0)

        var zipBytes = Data()
        zipBytes.append(cd)
        zipBytes.append(eocd)
        let hugeZipURL = dir.appendingPathComponent("huge_totals.zip")
        try zipBytes.write(to: hugeZipURL)

        let hugeZipPreview = await formatter.renderHTMLPreview(for: hugeZipURL)
        #expect(hugeZipPreview.formatName == "ZIP")
        #expect(!hugeZipPreview.html.isEmpty)
    }
}

@Suite(.serialized)
struct ExtensionHelperResolutionTests {
    @Test func enclosingAppHelperCandidates_resolvesHelpersFromAppexBundle() {
        let appexURL = URL(fileURLWithPath: "/Applications/BentoZip.app/Contents/PlugIns/BentoZipQuickLook.appex")
        let bento7zCandidates = Bento7zProcessRunner.enclosingAppHelperCandidates(
            fileName: "bento7z",
            bundleURL: appexURL
        )
        #expect(bento7zCandidates.contains("/Applications/BentoZip.app/Contents/Helpers/bento7z"))

        let libCandidates = Bento7zProcessRunner.enclosingAppHelperCandidates(
            fileName: "7z.so",
            bundleURL: appexURL
        )
        #expect(libCandidates.contains("/Applications/BentoZip.app/Contents/Helpers/7z.so"))

        let mainAppURL = URL(fileURLWithPath: "/Applications/BentoZip.app")
        #expect(Bento7zProcessRunner.enclosingAppHelperCandidates(fileName: "bento7z", bundleURL: mainAppURL).isEmpty)
    }
}
