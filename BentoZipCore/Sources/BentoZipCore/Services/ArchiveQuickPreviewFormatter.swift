import Foundation
import zlib

// MARK: - Public Result Models

/// Self-contained HTML5 Quick Look preview payload for an archive.
public struct ArchiveHTMLPreview: Sendable, Equatable {
    public let html: String
    public let entryCount: Int
    public let formatName: String

    public init(html: String, entryCount: Int, formatName: String) {
        self.html = html
        self.entryCount = entryCount
        self.formatName = formatName
    }
}

/// Spotlight index metadata extracted from an archive.
public struct ArchiveSpotlightMetadata: Sendable, Equatable {
    public let formatName: String
    public let itemCount: Int
    public let searchableText: String
    public let descriptionText: String

    public init(formatName: String, itemCount: Int, searchableText: String, descriptionText: String) {
        self.formatName = formatName
        self.itemCount = itemCount
        self.searchableText = searchableText
        self.descriptionText = descriptionText
    }
}

/// Lightweight archive entry record produced for Quick Look and Spotlight indexing.
public struct ArchivePreviewEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let packedSize: Int64?
    public let modificationDate: Date?
    public let isEncrypted: Bool

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        packedSize: Int64? = nil,
        modificationDate: Date? = nil,
        isEncrypted: Bool = false
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.packedSize = packedSize
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
    }
}

/// Result of fast in-process or engine-backed preview entry loading.
public struct ArchivePreviewResult: Sendable, Equatable {
    public let entries: [ArchivePreviewEntry]
    public let formatName: String
    public let totalEntryCount: Int
    public let totalUncompressedSize: Int64
    public let totalPackedSize: Int64
    public let scannedPackedSize: Int64?
    public let isEncrypted: Bool
    public let isTruncated: Bool
    public let requiresPassword: Bool

    public init(
        entries: [ArchivePreviewEntry],
        formatName: String,
        totalEntryCount: Int,
        totalUncompressedSize: Int64,
        totalPackedSize: Int64,
        scannedPackedSize: Int64? = nil,
        isEncrypted: Bool = false,
        isTruncated: Bool = false,
        requiresPassword: Bool = false
    ) {
        self.entries = entries
        self.formatName = formatName
        self.totalEntryCount = totalEntryCount
        self.totalUncompressedSize = totalUncompressedSize
        self.totalPackedSize = totalPackedSize
        self.scannedPackedSize = scannedPackedSize
        self.isEncrypted = isEncrypted
        self.isTruncated = isTruncated
        self.requiresPassword = requiresPassword
    }
}

// MARK: - Quick Preview & Spotlight Formatter

/// Shared fast archive preview and Spotlight metadata generator for BentoZip and its app extensions.
public struct ArchiveQuickPreviewFormatter: Sendable {
    public static let shared = ArchiveQuickPreviewFormatter()

    private static let maxSpotlightSearchableBytes = 128 * 1024
    private static let maxTarGzDecompressedPreviewBytes = 16 * 1024 * 1024
    private static let maxTarMetadataBlockBytes = 64 * 1024

    public init() {}

    // MARK: - Public API

    /// Load preview entries quickly in-process for ZIP/TAR formats, falling back to `Bento7zEngine` when accessible.
    public func loadPreviewEntries(
        for archiveURL: URL,
        maxEntries: Int = 500
    ) async -> ArchivePreviewResult {
        let clampedMax = max(0, maxEntries)
        let detectedFormat = FormatDetector.detectReadableFormat(of: archiveURL)
        let formatName = Self.resolvedFormatName(for: archiveURL, detectedFormat: detectedFormat)
        let archiveFileSize = Self.fileSize(at: archiveURL)

        let fastOutcome = await Task.detached(priority: .userInitiated) {
            Self.runFastInProcessReader(
                for: archiveURL,
                detectedFormat: detectedFormat,
                formatName: formatName,
                archiveFileSize: archiveFileSize,
                maxEntries: clampedMax
            )
        }.value

        if let parsed = fastOutcome.result, (!parsed.entries.isEmpty || fastOutcome.confirmedValidEmpty) {
            return parsed
        }

        let canUseEngineFallback = (detectedFormat == .aar) || Bento7zProcessRunner.isBinaryAvailable
        if canUseEngineFallback {
            if let engineResult = await Self.loadViaEngine(
                archiveURL: archiveURL,
                formatName: formatName,
                archiveFileSize: archiveFileSize,
                maxEntries: clampedMax
            ) {
                return engineResult
            }
        }

        return fastOutcome.result ?? ArchivePreviewResult(
            entries: [],
            formatName: formatName,
            totalEntryCount: 0,
            totalUncompressedSize: 0,
            totalPackedSize: archiveFileSize,
            isEncrypted: false,
            isTruncated: false,
            requiresPassword: false
        )
    }

    /// Generate a self-contained HTML5 Quick Look preview for an archive.
    public func renderHTMLPreview(
        for archiveURL: URL,
        maxEntries: Int = 500
    ) async -> ArchiveHTMLPreview {
        let result = await loadPreviewEntries(for: archiveURL, maxEntries: maxEntries)
        let html = Self.buildHTML(for: archiveURL, result: result)
        let entryCount = max(result.totalEntryCount, result.entries.count)
        return ArchiveHTMLPreview(
            html: html,
            entryCount: entryCount,
            formatName: result.formatName
        )
    }

    /// Extract Spotlight index metadata (`textContent` and concise summary) for an archive.
    public func extractSpotlightMetadata(
        for archiveURL: URL,
        maxEntries: Int = 1000
    ) async -> ArchiveSpotlightMetadata {
        let result = await loadPreviewEntries(for: archiveURL, maxEntries: maxEntries)
        let itemCount = max(result.totalEntryCount, result.entries.count)
        let searchableText = Self.buildSearchableText(from: result.entries)
        let descriptionText = Self.buildDescriptionText(
            formatName: result.formatName,
            itemCount: itemCount,
            requiresPassword: result.requiresPassword
        )
        return ArchiveSpotlightMetadata(
            formatName: result.formatName,
            itemCount: itemCount,
            searchableText: searchableText,
            descriptionText: descriptionText
        )
    }

    /// Strictly escape HTML special characters (`&`, `<`, `>`, `"`, `'`) in untrusted strings.
    public static func escapeHTML(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": output.append("&amp;")
            case "<": output.append("&lt;")
            case ">": output.append("&gt;")
            case "\"": output.append("&quot;")
            case "'": output.append("&#39;")
            default: output.append(char)
            }
        }
        return output
    }

    /// Strictly escape HTML special characters (`&`, `<`, `>`, `"`, `'`) in untrusted strings.
    public func escapeHTML(_ text: String) -> String {
        Self.escapeHTML(text)
    }

    // MARK: - Engine Fallback

    private static func loadViaEngine(
        archiveURL: URL,
        formatName: String,
        archiveFileSize: Int64,
        maxEntries: Int
    ) async -> ArchivePreviewResult? {
        do {
            let listResult = try await Bento7zEngine().listArchive(
                in: archiveURL,
                password: nil,
                encoding: nil,
                unwrapSingleTopDirectory: false,
                onProgress: nil
            )

            var entries: [ArchivePreviewEntry] = []
            entries.reserveCapacity(min(maxEntries, 128))
            var totalCount = 0
            var totalUncompressed: Int64 = 0
            var scannedPacked: Int64 = 0
            var hasPackedData = false
            var anyEncrypted = false

            func walk(_ nodes: [FileEntry]) {
                for node in nodes {
                    let rawPath = node.archiveRelativePath ?? node.name
                    if let safePath = sanitizeRelativePath(rawPath) {
                        totalCount += 1
                        if !node.isDirectory {
                            totalUncompressed = saturatingAdd(totalUncompressed, node.size)
                            if let packed = node.packedSize {
                                scannedPacked = saturatingAdd(scannedPacked, packed)
                                hasPackedData = true
                            }
                        }
                        if node.isEncrypted {
                            anyEncrypted = true
                        }
                        if entries.count < maxEntries {
                            let displayName = displayName(for: safePath, fallback: node.name)
                            entries.append(ArchivePreviewEntry(
                                path: safePath,
                                name: displayName,
                                isDirectory: node.isDirectory,
                                size: max(0, node.size),
                                packedSize: node.packedSize,
                                modificationDate: node.modificationDate,
                                isEncrypted: node.isEncrypted
                            ))
                        }
                    }
                    if let children = node.children, !children.isEmpty {
                        walk(children)
                    }
                }
            }

            walk(listResult.entries)

            let packedTotal = listResult.archivePackedSize ?? archiveFileSize
            return ArchivePreviewResult(
                entries: entries,
                formatName: formatName,
                totalEntryCount: totalCount,
                totalUncompressedSize: totalUncompressed,
                totalPackedSize: packedTotal,
                scannedPackedSize: hasPackedData ? scannedPacked : nil,
                isEncrypted: anyEncrypted,
                isTruncated: totalCount > entries.count,
                requiresPassword: false
            )
        } catch let error as Bento7zError {
            let isPasswordError = (error == .passwordRequired || error == .wrongPassword)
            if isPasswordError {
                return ArchivePreviewResult(
                    entries: [],
                    formatName: formatName,
                    totalEntryCount: 0,
                    totalUncompressedSize: 0,
                    totalPackedSize: archiveFileSize,
                    isEncrypted: true,
                    isTruncated: false,
                    requiresPassword: true
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Fast In-Process Dispatch

    private struct FastReadOutcome {
        let result: ArchivePreviewResult?
        let confirmedValidEmpty: Bool
    }

    private static func runFastInProcessReader(
        for archiveURL: URL,
        detectedFormat: ReadableArchiveFormat?,
        formatName: String,
        archiveFileSize: Int64,
        maxEntries: Int
    ) -> FastReadOutcome {
        switch detectedFormat {
        case .zip, .epub:
            if let outcome = readZIPPreview(
                at: archiveURL,
                formatName: formatName,
                archiveFileSize: archiveFileSize,
                maxEntries: maxEntries
            ) {
                return outcome
            }
            return FastReadOutcome(result: nil, confirmedValidEmpty: false)

        case .tar:
            if let outcome = readTARPreview(
                at: archiveURL,
                formatName: formatName,
                archiveFileSize: archiveFileSize,
                maxEntries: maxEntries
            ) {
                return outcome
            }
            return FastReadOutcome(result: nil, confirmedValidEmpty: false)

        case .tarGz:
            if let outcome = readTARGZPreview(
                at: archiveURL,
                formatName: formatName,
                archiveFileSize: archiveFileSize,
                maxEntries: maxEntries
            ) {
                return outcome
            }
            return FastReadOutcome(result: nil, confirmedValidEmpty: false)

        default:
            return FastReadOutcome(result: nil, confirmedValidEmpty: false)
        }
    }

    // MARK: - Pure-Swift ZIP Central Directory Reader

    private static func readZIPPreview(
        at archiveURL: URL,
        formatName: String,
        archiveFileSize: Int64,
        maxEntries: Int
    ) -> FastReadOutcome? {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else {
            return nil
        }

        let maxTailLength: UInt64 = 65_535 + 22
        let tailLength = Int(min(fileSize, maxTailLength))
        let tailStart = fileSize - UInt64(tailLength)
        guard (try? handle.seek(toOffset: tailStart)) != nil,
              let tailData = try? handle.read(upToCount: tailLength),
              tailData.count >= 22 else {
            return nil
        }

        let tail = [UInt8](tailData)
        guard let eocdIndex = findZipEOCDIndex(in: tail) else {
            return nil
        }

        let diskNumber = readUInt16LE(tail, at: eocdIndex + 4)
        let cdStartDisk = readUInt16LE(tail, at: eocdIndex + 6)
        guard diskNumber == 0, cdStartDisk == 0 else {
            return nil
        }

        let eocdFileOffset = tailStart + UInt64(eocdIndex)
        var totalEntries = UInt64(readUInt16LE(tail, at: eocdIndex + 10))
        var cdSize = UInt64(readUInt32LE(tail, at: eocdIndex + 12))
        var cdOffset = UInt64(readUInt32LE(tail, at: eocdIndex + 16))

        if totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            guard let zip64 = readZip64EOCD(handle: handle, eocdFileOffset: eocdFileOffset, fileSize: fileSize) else {
                return nil
            }
            totalEntries = zip64.totalEntries
            cdSize = zip64.cdSize
            cdOffset = zip64.cdOffset
        }

        guard cdOffset <= eocdFileOffset,
              cdSize <= eocdFileOffset - cdOffset else {
            return nil
        }

        if cdSize == 0 && totalEntries == 0 {
            let emptyResult = ArchivePreviewResult(
                entries: [],
                formatName: formatName,
                totalEntryCount: 0,
                totalUncompressedSize: 0,
                totalPackedSize: archiveFileSize,
                scannedPackedSize: 0,
                isEncrypted: false,
                isTruncated: false,
                requiresPassword: false
            )
            return FastReadOutcome(result: emptyResult, confirmedValidEmpty: true)
        }

        guard (try? handle.seek(toOffset: cdOffset)) != nil else {
            return nil
        }

        let cdEnd = cdOffset + cdSize
        var fileCursor = cdOffset
        var buffer = Data()
        var pos = 0

        func ensureBytes(_ needed: Int) -> Bool {
            if buffer.count - pos >= needed {
                return true
            }
            if pos > 0 {
                buffer.removeSubrange(0..<pos)
                pos = 0
            }
            while buffer.count < needed && fileCursor < cdEnd {
                let remaining = cdEnd >= fileCursor ? (cdEnd - fileCursor) : 0
                let chunkSize = Int(min(remaining, UInt64(max(262_144, needed - buffer.count))))
                guard chunkSize > 0,
                      let chunk = try? handle.read(upToCount: chunkSize),
                      !chunk.isEmpty else {
                    break
                }
                buffer.append(chunk)
                fileCursor += UInt64(chunk.count)
            }
            return buffer.count - pos >= needed
        }

        var entries: [ArchivePreviewEntry] = []
        entries.reserveCapacity(min(maxEntries, Int(min(totalEntries, 512))))
        var totalUncompressed: Int64 = 0
        var scannedPacked: Int64 = 0
        var anyEncrypted = false
        var parsedHeaders = 0

        while parsedHeaders < maxEntries && ensureBytes(46) {
            let sig0 = buffer[pos]
            let sig1 = buffer[pos + 1]
            let sig2 = buffer[pos + 2]
            let sig3 = buffer[pos + 3]
            guard sig0 == 0x50, sig1 == 0x4B, sig2 == 0x01, sig3 == 0x02 else {
                break
            }

            let header = [UInt8](buffer[pos..<(pos + 46)])
            let versionMadeBy = readUInt16LE(header, at: 4)
            let flags = readUInt16LE(header, at: 8)
            let dosTime = readUInt16LE(header, at: 12)
            let dosDate = readUInt16LE(header, at: 14)
            let compressedSize32 = readUInt32LE(header, at: 20)
            let uncompressedSize32 = readUInt32LE(header, at: 24)
            let nameLen = Int(readUInt16LE(header, at: 28))
            let extraLen = Int(readUInt16LE(header, at: 30))
            let commentLen = Int(readUInt16LE(header, at: 32))
            let externalAttrs = readUInt32LE(header, at: 38)

            let recordLength = 46 + nameLen + extraLen + commentLen
            guard ensureBytes(recordLength) else {
                break
            }

            let nameStart = pos + 46
            let nameEnd = nameStart + nameLen
            let extraEnd = nameEnd + extraLen

            let nameData = buffer.subdata(in: nameStart..<nameEnd)
            let extraBytes = extraLen > 0 ? [UInt8](buffer[nameEnd..<extraEnd]) : []

            pos += recordLength
            parsedHeaders += 1

            let rawName = decodeZipFilename(nameData, flags: flags)
            let (uncompressed64, compressed64) = resolveZipSizes(
                uncompressed32: uncompressedSize32,
                compressed32: compressedSize32,
                extraBytes: extraBytes
            )
            let uncompressed = clampedInt64(uncompressed64)
            let compressed = clampedInt64(compressed64)

            let hostOS = versionMadeBy >> 8
            let isUnixDir = (hostOS == 3 || hostOS == 19) && (((externalAttrs >> 16) & 0o170000) == 0o040000)
            let isDosDir = (externalAttrs & 0x10) != 0 && uncompressed == 0
            let isDirectory = rawName.hasSuffix("/") || rawName.hasSuffix("\\") || isUnixDir || isDosDir

            guard let safePath = sanitizeRelativePath(rawName) else {
                continue
            }

            let isEncrypted = (flags & 0x0001) != 0
            if isEncrypted {
                anyEncrypted = true
            }
            if !isDirectory {
                totalUncompressed = saturatingAdd(totalUncompressed, uncompressed)
                scannedPacked = saturatingAdd(scannedPacked, compressed)
            }

            let name = displayName(for: safePath, fallback: safePath)
            let modDate = dosDateTimeToDate(date: dosDate, time: dosTime)
            entries.append(ArchivePreviewEntry(
                path: safePath,
                name: name,
                isDirectory: isDirectory,
                size: uncompressed,
                packedSize: compressed,
                modificationDate: modDate,
                isEncrypted: isEncrypted
            ))
        }

        if totalEntries > 0 && entries.isEmpty && maxEntries > 0 {
            return nil
        }

        let safeTotalEntries = max(Int(min(totalEntries, UInt64(Int.max))), entries.count)
        let unconsumedFileBytes: UInt64 = cdEnd >= fileCursor ? (cdEnd - fileCursor) : 0
        let bufferedBytes = UInt64(max(0, buffer.count - pos))
        let (remainingUInt64, remainingOverflow) = unconsumedFileBytes.addingReportingOverflow(bufferedBytes)
        let clampedRemainingUInt64 = remainingOverflow ? UInt64(Int.max) : min(remainingUInt64, UInt64(Int.max))
        let remainingCDBytes = Int(clampedRemainingUInt64)
        let isTruncated = safeTotalEntries > entries.count || (parsedHeaders >= maxEntries && remainingCDBytes >= 46)

        let result = ArchivePreviewResult(
            entries: entries,
            formatName: formatName,
            totalEntryCount: safeTotalEntries,
            totalUncompressedSize: totalUncompressed,
            totalPackedSize: archiveFileSize > 0 ? archiveFileSize : scannedPacked,
            scannedPackedSize: scannedPacked,
            isEncrypted: anyEncrypted,
            isTruncated: isTruncated,
            requiresPassword: false
        )
        return FastReadOutcome(result: result, confirmedValidEmpty: safeTotalEntries == 0)
    }

    private static func findZipEOCDIndex(in tail: [UInt8]) -> Int? {
        guard tail.count >= 22 else { return nil }
        for idx in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail[idx] == 0x50 && tail[idx + 1] == 0x4B && tail[idx + 2] == 0x05 && tail[idx + 3] == 0x06 {
                let commentLen = Int(readUInt16LE(tail, at: idx + 20))
                if idx + 22 + commentLen == tail.count {
                    return idx
                }
            }
        }
        return nil
    }

    private static func readZip64EOCD(
        handle: FileHandle,
        eocdFileOffset: UInt64,
        fileSize: UInt64
    ) -> (totalEntries: UInt64, cdSize: UInt64, cdOffset: UInt64)? {
        guard eocdFileOffset >= 20 else { return nil }
        let locatorOffset = eocdFileOffset - 20
        guard (try? handle.seek(toOffset: locatorOffset)) != nil,
              let locatorData = try? handle.read(upToCount: 20),
              locatorData.count == 20 else {
            return nil
        }
        let locator = [UInt8](locatorData)
        guard locator[0] == 0x50, locator[1] == 0x4B, locator[2] == 0x06, locator[3] == 0x07 else {
            return nil
        }

        let zip64EOCDOffset = readUInt64LE(locator, at: 8)
        guard zip64EOCDOffset <= fileSize, fileSize - zip64EOCDOffset >= 56 else {
            return nil
        }
        guard (try? handle.seek(toOffset: zip64EOCDOffset)) != nil,
              let eocd64Data = try? handle.read(upToCount: 56),
              eocd64Data.count == 56 else {
            return nil
        }
        let eocd64 = [UInt8](eocd64Data)
        guard eocd64[0] == 0x50, eocd64[1] == 0x4B, eocd64[2] == 0x06, eocd64[3] == 0x06 else {
            return nil
        }

        let totalEntries = readUInt64LE(eocd64, at: 32)
        let cdSize = readUInt64LE(eocd64, at: 40)
        let cdOffset = readUInt64LE(eocd64, at: 48)
        return (totalEntries, cdSize, cdOffset)
    }

    private static func resolveZipSizes(
        uncompressed32: UInt32,
        compressed32: UInt32,
        extraBytes: [UInt8]
    ) -> (UInt64, UInt64) {
        var uncompressed = UInt64(uncompressed32)
        var compressed = UInt64(compressed32)
        guard uncompressed32 == 0xFFFFFFFF || compressed32 == 0xFFFFFFFF else {
            return (uncompressed, compressed)
        }

        var cursor = 0
        while cursor + 4 <= extraBytes.count {
            let headerID = readUInt16LE(extraBytes, at: cursor)
            let dataSize = Int(readUInt16LE(extraBytes, at: cursor + 2))
            cursor += 4
            guard cursor + dataSize <= extraBytes.count else { break }

            if headerID == 0x0001 {
                var fieldOffset = cursor
                if uncompressed32 == 0xFFFFFFFF, fieldOffset + 8 <= cursor + dataSize {
                    uncompressed = readUInt64LE(extraBytes, at: fieldOffset)
                    fieldOffset += 8
                }
                if compressed32 == 0xFFFFFFFF, fieldOffset + 8 <= cursor + dataSize {
                    compressed = readUInt64LE(extraBytes, at: fieldOffset)
                }
                break
            }
            cursor += dataSize
        }
        return (uncompressed, compressed)
    }

    private static func decodeZipFilename(_ data: Data, flags: UInt16) -> String {
        if (flags & 0x0800) != 0, let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let cp437CF = CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
        let cp437Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cp437CF))
        if let dos = String(data: data, encoding: cp437Encoding) {
            return dos
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func dosDateTimeToDate(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 || time != 0 else { return nil }
        let second = Int(time & 0x1F) * 2
        let minute = Int((time >> 5) & 0x3F)
        let hour = Int((time >> 11) & 0x1F)
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0x0F)
        let year = Int((date >> 9) & 0x7F) + 1980

        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date
    }

    // MARK: - Pure-Swift TAR & TAR.GZ USTAR Reader

    private static func readTARPreview(
        at archiveURL: URL,
        formatName: String,
        archiveFileSize: Int64,
        maxEntries: Int
    ) -> FastReadOutcome? {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 512 else { return nil }
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }

        var parser = TarHeaderStreamParser(maxEntries: maxEntries)
        var offset: UInt64 = 0

        while offset + 512 <= fileSize {
            if parser.pendingDataSkipBytes > 0 {
                let skip = UInt64(parser.pendingDataSkipBytes)
                parser.pendingDataSkipBytes = 0
                let (nextOffset, overflow) = offset.addingReportingOverflow(skip)
                if overflow || nextOffset > fileSize {
                    break
                }
                offset = nextOffset
                guard (try? handle.seek(toOffset: offset)) != nil else { break }
                continue
            }

            guard let blockData = try? handle.read(upToCount: 512), blockData.count == 512 else {
                break
            }
            offset += 512

            switch parser.feedBlock([UInt8](blockData)) {
            case .continue:
                continue
            case .done:
                return parser.makeOutcome(formatName: formatName, archiveFileSize: archiveFileSize)
            case .invalidFormat:
                return nil
            }
        }

        return parser.makeOutcome(formatName: formatName, archiveFileSize: archiveFileSize)
    }

    private static func readTARGZPreview(
        at archiveURL: URL,
        formatName: String,
        archiveFileSize: Int64,
        maxEntries: Int
    ) -> FastReadOutcome? {
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            16 + MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var parser = TarHeaderStreamParser(maxEntries: maxEntries)
        var blockBuffer: [UInt8] = []
        blockBuffer.reserveCapacity(65_536)
        var outChunk = [UInt8](repeating: 0, count: 65_536)
        var totalDecompressedBytes = 0
        var reachedStreamEnd = false
        var hitPreviewCap = false

        inputLoop: while !reachedStreamEnd && !hitPreviewCap {
            guard let inData = try? handle.read(upToCount: 65_536), !inData.isEmpty else {
                break
            }
            var inBytes = [UInt8](inData)
            let inCount = inBytes.count

            var inflateResult: Int32 = Z_OK
            inBytes.withUnsafeMutableBufferPointer { inPtr in
                stream.next_in = inPtr.baseAddress
                stream.avail_in = uInt(inCount)

                while !reachedStreamEnd && !hitPreviewCap {
                    let producedCount: Int = outChunk.withUnsafeMutableBufferPointer { outPtr in
                        stream.next_out = outPtr.baseAddress
                        stream.avail_out = uInt(outPtr.count)
                        inflateResult = inflate(&stream, Z_NO_FLUSH)
                        return outPtr.count - Int(stream.avail_out)
                    }

                    if producedCount > 0 {
                        totalDecompressedBytes += producedCount
                        blockBuffer.append(contentsOf: outChunk[0..<producedCount])

                        while blockBuffer.count >= 512 {
                            let block = Array(blockBuffer[0..<512])
                            blockBuffer.removeFirst(512)

                            switch parser.feedBlock(block) {
                            case .continue:
                                break
                            case .done:
                                reachedStreamEnd = true
                                return
                            case .invalidFormat:
                                parser.markInvalid()
                                reachedStreamEnd = true
                                return
                            }
                        }
                    }

                    if inflateResult == Z_STREAM_END {
                        reachedStreamEnd = true
                        break
                    }
                    if inflateResult != Z_OK && inflateResult != Z_BUF_ERROR {
                        reachedStreamEnd = true
                        break
                    }
                    if totalDecompressedBytes >= maxTarGzDecompressedPreviewBytes {
                        hitPreviewCap = true
                        break
                    }
                    if stream.avail_out > 0 && stream.avail_in == 0 {
                        break
                    }
                    if producedCount == 0 && stream.avail_in == 0 {
                        break
                    }
                }
            }

            if parser.isInvalid {
                return nil
            }
            if inflateResult != Z_OK && inflateResult != Z_BUF_ERROR && inflateResult != Z_STREAM_END {
                break inputLoop
            }
        }

        if parser.isInvalid || (!parser.sawValidBlock && parser.entries.isEmpty) {
            return nil
        }

        if hitPreviewCap && !parser.isTruncated && !reachedStreamEnd {
            parser.markTruncated()
        }
        return parser.makeOutcome(formatName: formatName, archiveFileSize: archiveFileSize)
    }

    private struct TarHeaderStreamParser {
        enum StepResult {
            case `continue`
            case done
            case invalidFormat
        }

        let maxEntries: Int
        var entries: [ArchivePreviewEntry] = []
        var totalUncompressedSize: Int64 = 0
        var pendingDataSkipBytes: Int64 = 0
        var sawValidBlock = false
        var isTruncated = false
        var isInvalid = false

        private enum PendingPayloadKind {
            case gnuLongName
            case paxExtendedHeader
        }

        private var pendingPayloadKind: PendingPayloadKind?
        private var pendingMetadataSkipBytes: Int64 = 0
        private var pendingPayloadRemaining: Int64 = 0
        private var pendingPayloadBuffer = Data()
        private var nextLongName: String?
        private var nextPaxPath: String?
        private var nextPaxSize: Int64?

        init(maxEntries: Int) {
            self.maxEntries = maxEntries
        }

        mutating func markInvalid() {
            isInvalid = true
        }

        mutating func markTruncated() {
            isTruncated = true
        }

        mutating func feedBlock(_ block: [UInt8]) -> StepResult {
            guard block.count == 512 else { return .done }

            if pendingPayloadKind != nil {
                return consumeMetadataPayloadBlock(block)
            }

            if pendingDataSkipBytes > 0 {
                pendingDataSkipBytes = max(0, pendingDataSkipBytes - 512)
                return .continue
            }

            if block.allSatisfy({ $0 == 0 }) {
                return .done
            }

            let hasUstarMagic = block[257] == 0x75
                && block[258] == 0x73
                && block[259] == 0x74
                && block[260] == 0x61
                && block[261] == 0x72
            guard hasUstarMagic else {
                return sawValidBlock ? .done : .invalidFormat
            }

            guard let parsedSize = parseTarNumber(Array(block[124..<136])), parsedSize >= 0 else {
                return sawValidBlock ? .done : .invalidFormat
            }

            sawValidBlock = true
            let typeFlag = block[156]

            // Handle GNU LongName ('L'), LongLink ('K'), PAX extended ('x'), PAX global ('g')
            if typeFlag == UInt8(ascii: "L") || typeFlag == UInt8(ascii: "x")
                || typeFlag == UInt8(ascii: "K") || typeFlag == UInt8(ascii: "g") {
                guard let padded = paddedTarSize(parsedSize) else {
                    return .done
                }
                if parsedSize > 0 && parsedSize <= Int64(maxTarGzDecompressedPreviewBytes) {
                    if (typeFlag == UInt8(ascii: "L") || typeFlag == UInt8(ascii: "x"))
                        && parsedSize <= Int64(maxTarMetadataBlockBytes) {
                        pendingPayloadKind = (typeFlag == UInt8(ascii: "L")) ? .gnuLongName : .paxExtendedHeader
                        pendingMetadataSkipBytes = padded
                        pendingPayloadRemaining = parsedSize
                        pendingPayloadBuffer.removeAll(keepingCapacity: true)
                        return .continue
                    } else {
                        pendingDataSkipBytes = padded
                        return .continue
                    }
                }
                return .continue
            }

            let namePart = decodeTarString(Array(block[0..<100]))
            let prefixPart = decodeTarString(Array(block[345..<500]))
            let ustarPath = prefixPart.isEmpty ? namePart : "\(prefixPart)/\(namePart)"

            let effectivePath = nextPaxPath ?? nextLongName ?? ustarPath
            let effectiveSize = nextPaxSize ?? parsedSize
            nextPaxPath = nil
            nextLongName = nil
            nextPaxSize = nil

            guard effectiveSize >= 0, let paddedSize = paddedTarSize(effectiveSize) else {
                return .done
            }

            let mtimeSeconds = parseTarNumber(Array(block[136..<148])) ?? 0
            let modDate = mtimeSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(mtimeSeconds)) : nil
            let isDirectory = typeFlag == UInt8(ascii: "5") || effectivePath.hasSuffix("/")

            if entries.count >= maxEntries {
                isTruncated = true
                return .done
            }

            if let safePath = sanitizeRelativePath(effectivePath) {
                let entryName = displayName(for: safePath, fallback: safePath)
                if !isDirectory {
                    totalUncompressedSize = saturatingAdd(totalUncompressedSize, effectiveSize)
                }
                entries.append(ArchivePreviewEntry(
                    path: safePath,
                    name: entryName,
                    isDirectory: isDirectory,
                    size: effectiveSize,
                    packedSize: nil,
                    modificationDate: modDate,
                    isEncrypted: false
                ))
            }

            pendingDataSkipBytes = paddedSize
            return .continue
        }

        private mutating func consumeMetadataPayloadBlock(_ block: [UInt8]) -> StepResult {
            pendingMetadataSkipBytes = max(0, pendingMetadataSkipBytes - 512)
            if pendingPayloadRemaining > 0 {
                let take = Int(min(pendingPayloadRemaining, 512))
                pendingPayloadBuffer.append(contentsOf: block[0..<take])
                pendingPayloadRemaining -= Int64(take)
            }

            if pendingMetadataSkipBytes == 0 {
                let kind = pendingPayloadKind
                pendingPayloadKind = nil
                switch kind {
                case .gnuLongName:
                    if let decoded = String(data: pendingPayloadBuffer, encoding: .utf8) {
                        nextLongName = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n"))
                    }
                case .paxExtendedHeader:
                    applyPaxPayload(pendingPayloadBuffer)
                case .none:
                    break
                }
                pendingPayloadBuffer.removeAll(keepingCapacity: false)
            }
            return .continue
        }

        private mutating func applyPaxPayload(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let spaceIdx = line.firstIndex(of: " ") else { continue }
                let rest = line[line.index(after: spaceIdx)...]
                guard let eqIdx = rest.firstIndex(of: "=") else { continue }
                let key = rest[..<eqIdx]
                let value = String(rest[rest.index(after: eqIdx)...])
                if key == "path" {
                    nextPaxPath = value
                } else if key == "size", let parsed = Int64(value), parsed >= 0 {
                    nextPaxSize = parsed
                }
            }
        }

        func makeOutcome(formatName: String, archiveFileSize: Int64) -> FastReadOutcome? {
            guard sawValidBlock || !entries.isEmpty else { return nil }
            let result = ArchivePreviewResult(
                entries: entries,
                formatName: formatName,
                totalEntryCount: entries.count,
                totalUncompressedSize: totalUncompressedSize,
                totalPackedSize: archiveFileSize,
                scannedPackedSize: nil,
                isEncrypted: false,
                isTruncated: isTruncated,
                requiresPassword: false
            )
            return FastReadOutcome(result: result, confirmedValidEmpty: sawValidBlock && entries.isEmpty)
        }

        private func paddedTarSize(_ size: Int64) -> Int64? {
            guard size >= 0 else { return nil }
            if size == 0 { return 0 }
            let (withPad, overflow1) = size.addingReportingOverflow(511)
            guard !overflow1 else { return nil }
            let blocks = withPad / 512
            let (padded, overflow2) = blocks.multipliedReportingOverflow(by: 512)
            return overflow2 ? nil : padded
        }

        private func decodeTarString(_ bytes: [UInt8]) -> String {
            let trimmed = bytes.prefix(while: { $0 != 0 })
            if trimmed.isEmpty { return "" }
            return String(decoding: trimmed, as: UTF8.self)
        }

        private func parseTarNumber(_ bytes: [UInt8]) -> Int64? {
            guard !bytes.isEmpty else { return 0 }
            // GNU base-256 big-endian encoding when high bit is set on first byte
            if (bytes[0] & 0x80) != 0 {
                // Reject negative GNU base-256 numbers (second bit 0x40 set)
                guard (bytes[0] & 0x40) == 0 else { return nil }
                var value: UInt64 = UInt64(bytes[0] & 0x3F)
                for byte in bytes.dropFirst() {
                    if value > (UInt64(Int64.max) >> 8) {
                        return nil
                    }
                    value = (value << 8) | UInt64(byte)
                }
                return Int64(value)
            }

            let raw = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return 0 }
            guard !raw.hasPrefix("-") else { return nil }
            var value: Int64 = 0
            for scalar in raw.unicodeScalars {
                guard scalar.value >= 48 && scalar.value <= 55 else { return nil }
                let digit = Int64(scalar.value - 48)
                let (shifted, overflow1) = value.multipliedReportingOverflow(by: 8)
                guard !overflow1 else { return nil }
                let (sum, overflow2) = shifted.addingReportingOverflow(digit)
                guard !overflow2 else { return nil }
                value = sum
            }
            return value
        }
    }

    // MARK: - HTML Builder

    private static func buildHTML(for archiveURL: URL, result: ArchivePreviewResult) -> String {
        let escapedFileName = escapeHTML(archiveURL.lastPathComponent)
        let escapedFormat = escapeHTML(result.formatName)
        let itemCount = max(result.totalEntryCount, result.entries.count)

        let itemLabel: String
        if result.requiresPassword && itemCount == 0 {
            itemLabel = "Protected"
        } else {
            itemLabel = "\(itemCount) \(itemCount == 1 ? "item" : "items")"
        }

        let uncompressedLabel: String
        if result.requiresPassword && result.totalUncompressedSize == 0 && result.entries.isEmpty {
            uncompressedLabel = "—"
        } else {
            uncompressedLabel = formatByteCount(result.totalUncompressedSize)
        }

        let packedLabel = formatByteCount(result.totalPackedSize)
        let savedLabel = computeSavedLabel(for: result)

        var badgesHTML = "<span class=\"badge badge-format\">\(escapedFormat)</span>"
        if result.isEncrypted {
            badgesHTML += "<span class=\"badge badge-encrypted\">Encrypted</span>"
        }

        var rowsHTML = ""
        rowsHTML.reserveCapacity(min(result.entries.count, 500) * 160)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for entry in result.entries {
            let escapedPath = escapeHTML(entry.path)
            let sizeText = entry.isDirectory ? "—" : escapeHTML(formatByteCount(entry.size))
            let dateText = entry.modificationDate.map { escapeHTML(dateFormatter.string(from: $0)) } ?? "—"
            let iconSVG = entry.isDirectory ? folderIconSVG : fileIconSVG
            let lockBadge = entry.isEncrypted ? "<span class=\"entry-lock\" title=\"Encrypted\">Locked</span>" : ""

            rowsHTML += """
            <tr>
              <td class="name-cell">
                <span class="entry-name">\(iconSVG)<span class="path-text">\(escapedPath)</span>\(lockBadge)</span>
              </td>
              <td class="size-cell">\(sizeText)</td>
              <td class="date-cell">\(dateText)</td>
            </tr>
            """
        }

        let bodyContent: String
        if result.requiresPassword || (result.entries.isEmpty && result.isEncrypted) {
            bodyContent = """
            <div class="empty-card">
              <div class="empty-title">Encrypted Archive</div>
              <div class="empty-subtitle">Open this archive in BentoZip and enter the password to browse or extract its contents.</div>
            </div>
            """
        } else if result.entries.isEmpty {
            bodyContent = """
            <div class="empty-card">
              <div class="empty-title">No Previewable Entries</div>
              <div class="empty-subtitle">This archive contains no listable items or requires opening in BentoZip.</div>
            </div>
            """
        } else {
            bodyContent = """
            <div class="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th class="size-col">Size</th>
                    <th class="date-col">Modified</th>
                  </tr>
                </thead>
                <tbody>
                  \(rowsHTML)
                </tbody>
              </table>
            </div>
            """
        }

        var footerNotes: [String] = []
        if result.isTruncated {
            if itemCount > result.entries.count {
                footerNotes.append("Showing first \(result.entries.count) of \(itemCount) items.")
            } else {
                footerNotes.append("Preview listing capped at \(result.entries.count) items.")
            }
        }
        if !result.requiresPassword && result.isEncrypted && !result.entries.isEmpty {
            footerNotes.append("Contains encrypted entries; password required to extract.")
        }

        let footerHTML: String
        if footerNotes.isEmpty {
            footerHTML = ""
        } else {
            let escapedNote = escapeHTML(footerNotes.joined(separator: " "))
            footerHTML = "<footer class=\"footer-note\">\(escapedNote)</footer>"
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapedFileName)</title>
          <style>
            :root {
              color-scheme: light dark;
              --bg: #f5f5f7;
              --surface: #ffffff;
              --surface-alt: #f9fafb;
              --text: #1d1d1f;
              --muted: #6e6e73;
              --border: rgba(0, 0, 0, 0.1);
              --row-hover: rgba(0, 122, 255, 0.06);
              --badge-format-bg: rgba(0, 122, 255, 0.12);
              --badge-format-fg: #0066cc;
              --badge-enc-bg: rgba(255, 149, 0, 0.15);
              --badge-enc-fg: #b25000;
              --icon-folder: #007aff;
              --icon-file: #8e8e93;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #1c1c1e;
                --surface: #2c2c2e;
                --surface-alt: #242426;
                --text: #f5f5f7;
                --muted: #98989d;
                --border: rgba(255, 255, 255, 0.12);
                --row-hover: rgba(10, 132, 255, 0.14);
                --badge-format-bg: rgba(10, 132, 255, 0.22);
                --badge-format-fg: #64b5ff;
                --badge-enc-bg: rgba(255, 159, 10, 0.22);
                --badge-enc-fg: #ffb340;
                --icon-folder: #0a84ff;
                --icon-file: #98989d;
              }
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 20px;
              background: var(--bg);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
              font-size: 13px;
              line-height: 1.45;
            }
            .container {
              max-width: 960px;
              margin: 0 auto;
              display: flex;
              flex-direction: column;
              gap: 14px;
            }
            .summary-card {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 16px 18px;
            }
            .title-row {
              display: flex;
              align-items: center;
              flex-wrap: wrap;
              gap: 8px;
              margin-bottom: 12px;
            }
            .archive-title {
              margin: 0;
              font-size: 17px;
              font-weight: 600;
              word-break: break-word;
            }
            .badge {
              display: inline-flex;
              align-items: center;
              padding: 2px 8px;
              border-radius: 999px;
              font-size: 11px;
              font-weight: 600;
              letter-spacing: 0.02em;
            }
            .badge-format {
              background: var(--badge-format-bg);
              color: var(--badge-format-fg);
            }
            .badge-encrypted {
              background: var(--badge-enc-bg);
              color: var(--badge-enc-fg);
            }
            .stats-grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
              gap: 10px 16px;
            }
            .stat {
              display: flex;
              flex-direction: column;
              gap: 2px;
            }
            .stat-label {
              font-size: 11px;
              color: var(--muted);
              text-transform: uppercase;
              letter-spacing: 0.04em;
            }
            .stat-value {
              font-size: 14px;
              font-weight: 600;
              font-variant-numeric: tabular-nums;
            }
            .table-wrap {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 12px;
              overflow: hidden;
            }
            table {
              width: 100%;
              border-collapse: collapse;
              table-layout: fixed;
            }
            thead th {
              background: var(--surface-alt);
              color: var(--muted);
              font-size: 11px;
              font-weight: 600;
              text-transform: uppercase;
              letter-spacing: 0.04em;
              text-align: left;
              padding: 10px 14px;
              border-bottom: 1px solid var(--border);
            }
            th.size-col, td.size-cell {
              width: 110px;
              text-align: right;
              font-variant-numeric: tabular-nums;
              white-space: nowrap;
            }
            th.date-col, td.date-cell {
              width: 170px;
              text-align: right;
              color: var(--muted);
              white-space: nowrap;
            }
            tbody td {
              padding: 8px 14px;
              border-bottom: 1px solid var(--border);
              vertical-align: middle;
            }
            tbody tr:last-child td {
              border-bottom: none;
            }
            tbody tr:hover {
              background: var(--row-hover);
            }
            .entry-name {
              display: flex;
              align-items: center;
              gap: 8px;
              min-width: 0;
            }
            .path-text {
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .entry-lock {
              flex-shrink: 0;
              font-size: 10px;
              font-weight: 600;
              padding: 1px 6px;
              border-radius: 999px;
              background: var(--badge-enc-bg);
              color: var(--badge-enc-fg);
            }
            .icon {
              width: 15px;
              height: 15px;
              flex-shrink: 0;
            }
            .icon-folder { color: var(--icon-folder); }
            .icon-file { color: var(--icon-file); }
            .empty-card {
              background: var(--surface);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 28px 20px;
              text-align: center;
            }
            .empty-title {
              font-size: 15px;
              font-weight: 600;
              margin-bottom: 6px;
            }
            .empty-subtitle {
              color: var(--muted);
            }
            .footer-note {
              color: var(--muted);
              font-size: 12px;
              text-align: center;
              padding: 2px 8px;
            }
          </style>
        </head>
        <body>
          <main class="container">
            <section class="summary-card">
              <div class="title-row">
                <h1 class="archive-title">\(escapedFileName)</h1>
                \(badgesHTML)
              </div>
              <div class="stats-grid">
                <div class="stat">
                  <span class="stat-label">Items</span>
                  <span class="stat-value">\(escapeHTML(itemLabel))</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Uncompressed</span>
                  <span class="stat-value">\(escapeHTML(uncompressedLabel))</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Packed Size</span>
                  <span class="stat-value">\(escapeHTML(packedLabel))</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Space Saved</span>
                  <span class="stat-value">\(escapeHTML(savedLabel))</span>
                </div>
              </div>
            </section>
            \(bodyContent)
            \(footerHTML)
          </main>
        </body>
        </html>
        """
    }

    private static let folderIconSVG = """
    <svg class="icon icon-folder" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M1.75 2.5A1.25 1.25 0 0 0 .5 3.75v8.5c0 .69.56 1.25 1.25 1.25h12.5c.69 0 1.25-.56 1.25-1.25v-6.5c0-.69-.56-1.25-1.25-1.25H7.79l-1.36-1.56A1.25 1.25 0 0 0 5.49 2.5H1.75Z"/></svg>
    """

    private static let fileIconSVG = """
    <svg class="icon icon-file" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M4 1.5A1.5 1.5 0 0 0 2.5 3v10A1.5 1.5 0 0 0 4 14.5h8A1.5 1.5 0 0 0 13.5 13V5.62a1.5 1.5 0 0 0-.44-1.06L9.94 1.44A1.5 1.5 0 0 0 8.88 1H4Zm4.5 1.25L12.25 6.5H9a.5.5 0 0 1-.5-.5V2.75Z"/></svg>
    """

    private static func computeSavedLabel(for result: ArchivePreviewResult) -> String {
        guard result.totalUncompressedSize > 0 else { return "—" }
        let packedReference: Int64
        if result.isTruncated, let scanned = result.scannedPackedSize, scanned > 0 {
            packedReference = scanned
        } else {
            packedReference = result.totalPackedSize
        }
        guard packedReference >= 0 else { return "—" }
        let ratio = (1.0 - (Double(packedReference) / Double(result.totalUncompressedSize))) * 100.0
        let clamped = min(max(ratio, 0.0), 100.0)
        return String(format: "%.1f%%", clamped)
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    // MARK: - Spotlight Metadata Builders

    private static func buildSearchableText(from entries: [ArchivePreviewEntry]) -> String {
        var seen = Set<String>()
        var output = ""
        var currentUTF8Bytes = 0

        for entry in entries {
            let candidates = entry.name == entry.path ? [entry.path] : [entry.path, entry.name]
            for raw in candidates {
                let sanitized = raw
                    .replacingOccurrences(of: "\0", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sanitized.isEmpty, seen.insert(sanitized).inserted else { continue }

                let separatorBytes = output.isEmpty ? 0 : 1
                let entryBytes = sanitized.utf8.count
                if currentUTF8Bytes + separatorBytes + entryBytes <= maxSpotlightSearchableBytes {
                    if !output.isEmpty {
                        output.append("\n")
                        currentUTF8Bytes += 1
                    }
                    output.append(sanitized)
                    currentUTF8Bytes += entryBytes
                } else {
                    let budget = maxSpotlightSearchableBytes - currentUTF8Bytes - separatorBytes
                    if budget > 0 {
                        let truncated = truncateUTF8(sanitized, maxBytes: budget)
                        if !truncated.isEmpty {
                            if !output.isEmpty { output.append("\n") }
                            output.append(truncated)
                        }
                    }
                    return output
                }
            }
        }
        return output
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        var bytesUsed = 0
        for char in text {
            let charBytes = String(char).utf8.count
            if bytesUsed + charBytes > maxBytes { break }
            result.append(char)
            bytesUsed += charBytes
        }
        return result
    }

    private static func buildDescriptionText(
        formatName: String,
        itemCount: Int,
        requiresPassword: Bool
    ) -> String {
        if requiresPassword && itemCount == 0 {
            return "\(formatName) encrypted archive"
        }
        let unit = itemCount == 1 ? "item" : "items"
        return "\(formatName) archive containing \(itemCount) \(unit)"
    }

    // MARK: - Shared Path & Byte Helpers

    private static func resolvedFormatName(for archiveURL: URL, detectedFormat: ReadableArchiveFormat?) -> String {
        if let detectedFormat {
            return detectedFormat.displayName
        }
        let ext = archiveURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "Archive" : ext.uppercased()
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func sanitizeRelativePath(_ rawPath: String) -> String? {
        try? Bento7zPathSafety.sanitizedRelativePath(rawPath)
    }

    private static func displayName(for sanitizedPath: String, fallback: String) -> String {
        if let last = sanitizedPath.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return fallback
    }

    private static func clampedInt64(_ value: UInt64) -> Int64 {
        Int64(min(value, UInt64(Int64.max)))
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let safeRHS = max(0, rhs)
        let (sum, overflow) = lhs.addingReportingOverflow(safeRHS)
        return overflow ? Int64.max : sum
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(readUInt32LE(bytes, at: offset))
            | (UInt64(readUInt32LE(bytes, at: offset + 4)) << 32)
    }
}
