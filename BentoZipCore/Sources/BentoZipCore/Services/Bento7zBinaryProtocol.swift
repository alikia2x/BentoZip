import Foundation

/// Compact little-endian binary wire codec shared with `bento7z --server <socket-path>`.
/// Matches `bento7z/src/binary_protocol.hpp` byte-for-byte.
enum Bento7zBinaryProtocol {
    static let headerSize = 13
    static let maxPayloadLength: UInt32 = 64 * 1024 * 1024

    enum RequestType: UInt8 {
        case list = 1
        case extract = 2
        case compress = 3
        case add = 4
        case delete = 5
        case cancel = 6
        case ping = 7
        case rename = 8
        case test = 9
    }

    enum ResponseType: UInt8 {
        case progress = 101
        case listMeta = 102
        case listChunk = 103
        case result = 104
        case error = 105
        case pong = 106
    }

    struct Frame: Sendable {
        let type: ResponseType
        let requestID: UInt64
        let payload: Data
    }

    struct ProgressPayload: Sendable {
        let stage: ArchiveProgress.Stage
        let processedBytes: Int64
        let totalBytes: Int64
        let filesDelta: Int
        let currentFile: String
    }

    struct ListMetaPayload: Sendable {
        let itemsCount: UInt64
        let totalSize: Int64
        let packedSize: Int64
        let usedTarCache: Bool
    }

    struct ResultPayload: Sendable {
        let archiveDeleted: Bool
        let outputSize: Int64
    }

    struct ErrorPayload: Sendable {
        let code: String
        let message: String
    }

    // MARK: - Frame Encoding

    static func encodeFrame(type: RequestType, requestID: UInt64, payload: Data = Data()) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        appendUInt32(UInt32(payload.count), to: &out)
        out.append(type.rawValue)
        appendUInt64(requestID, to: &out)
        out.append(payload)
        return out
    }

    static func encodeListRequest(
        archivePath: String,
        password: String?,
        format: String?,
        tarCachePath: String?,
        encoding: String? = nil
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendString(tarCachePath ?? "", to: &payload)
        appendString(encoding ?? "", to: &payload)
        return payload
    }

    static func encodeExtractRequest(
        archivePath: String,
        outputDir: String,
        password: String?,
        format: String?,
        tarCachePath: String?,
        entries: [String],
        encoding: String? = nil
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(outputDir, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendString(tarCachePath ?? "", to: &payload)
        appendStringArray(entries, to: &payload)
        appendString(encoding ?? "", to: &payload)
        return payload
    }

    static func encodeCompressRequest(
        archivePath: String,
        format: String,
        level: String,
        password: String?,
        preservePaths: Bool,
        paths: [String],
        exclude: [String],
        volumeSizeBytes: Int64 = 0,
        encryptionMethod: String? = nil
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(format, to: &payload)
        appendString(level, to: &payload)
        appendString(password ?? "", to: &payload)
        payload.append(preservePaths ? 1 : 0)
        appendStringArray(paths, to: &payload)
        appendStringArray(exclude, to: &payload)
        appendUInt64(UInt64(max(0, volumeSizeBytes)), to: &payload)
        appendString(encryptionMethod ?? "", to: &payload)
        return payload
    }

    static func encodeAddRequest(
        archivePath: String,
        password: String?,
        format: String?,
        paths: [String],
        targetPrefix: String? = nil
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendStringArray(paths, to: &payload)
        appendString(targetPrefix ?? "", to: &payload)
        return payload
    }

    static func encodeDeleteRequest(
        archivePath: String,
        password: String?,
        format: String?,
        entries: [String]
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendStringArray(entries, to: &payload)
        return payload
    }

    static func encodeRenameRequest(
        archivePath: String,
        password: String?,
        format: String?,
        oldPath: String,
        newPath: String
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendString(oldPath, to: &payload)
        appendString(newPath, to: &payload)
        return payload
    }

    static func encodeTestRequest(
        archivePath: String,
        password: String?,
        format: String?,
        tarCachePath: String?
    ) -> Data {
        var payload = Data()
        appendString(archivePath, to: &payload)
        appendString(password ?? "", to: &payload)
        appendString(format ?? "", to: &payload)
        appendString(tarCachePath ?? "", to: &payload)
        return payload
    }

    // MARK: - Payload Decoding

    static func decodeProgress(_ data: Data) throws -> ProgressPayload {
        var cursor = BinaryReader(data: data)
        let rawStage = try cursor.readUInt8()
        let processed = Int64(bitPattern: try cursor.readUInt64())
        let total = Int64(bitPattern: try cursor.readUInt64())
        let filesDelta = Int(try cursor.readUInt32())
        let currentFile = try cursor.readString()
        let stage = ArchiveProgress.Stage(rawValue: rawStage) ?? .normal
        return ProgressPayload(
            stage: stage,
            processedBytes: max(0, processed),
            totalBytes: max(0, total),
            filesDelta: filesDelta,
            currentFile: currentFile
        )
    }

    static func decodeListMeta(_ data: Data) throws -> ListMetaPayload {
        var cursor = BinaryReader(data: data)
        let itemsCount = try cursor.readUInt64()
        let totalSize = Int64(bitPattern: try cursor.readUInt64())
        let packedSize = Int64(bitPattern: try cursor.readUInt64())
        let usedTarCache = (try cursor.readUInt8()) != 0
        return ListMetaPayload(
            itemsCount: itemsCount,
            totalSize: max(0, totalSize),
            packedSize: max(0, packedSize),
            usedTarCache: usedTarCache
        )
    }

    static func decodeListChunk(_ data: Data) throws -> [ArchiveTreeBuilder.FlatEntry] {
        var cursor = BinaryReader(data: data)
        let count = Int(try cursor.readUInt32())
        var result: [ArchiveTreeBuilder.FlatEntry] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            let flags = try cursor.readUInt8()
            let size = Int64(bitPattern: try cursor.readUInt64())
            let packedSize = Int64(bitPattern: try cursor.readUInt64())
            let modifiedAtRaw = try cursor.readInt64()
            let hasCRC = (flags & 0x08) != 0
            let crc: UInt32? = hasCRC ? try cursor.readUInt32() : nil
            let path = try cursor.readString()
            let name = try cursor.readString()

            let isDir = (flags & 0x01) != 0
            let isEncrypted = (flags & 0x02) != 0
            let hasModDate = (flags & 0x04) != 0
            let modDate = (hasModDate && modifiedAtRaw > 0)
                ? Date(timeIntervalSince1970: Double(modifiedAtRaw))
                : nil

            result.append(ArchiveTreeBuilder.FlatEntry(
                path: path,
                name: name.isEmpty ? (path as NSString).lastPathComponent : name,
                isDirectory: isDir,
                size: max(0, size),
                packedSize: packedSize > 0 ? packedSize : nil,
                modificationDate: modDate,
                crc: crc,
                isEncrypted: isEncrypted
            ))
        }
        return result
    }

    static func decodeResult(_ data: Data) throws -> ResultPayload {
        var cursor = BinaryReader(data: data)
        let archiveDeleted = (try cursor.readUInt8()) != 0
        let outputSize = Int64(bitPattern: try cursor.readUInt64())
        return ResultPayload(archiveDeleted: archiveDeleted, outputSize: max(0, outputSize))
    }

    static func decodeError(_ data: Data) throws -> ErrorPayload {
        var cursor = BinaryReader(data: data)
        let code = try cursor.readString()
        let message = try cursor.readString()
        return ErrorPayload(code: code, message: message)
    }

    // MARK: - Primitives

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let utf8 = value.utf8
        appendUInt32(UInt32(utf8.count), to: &data)
        data.append(contentsOf: utf8)
    }

    private static func appendStringArray(_ values: [String], to data: inout Data) {
        appendUInt32(UInt32(values.count), to: &data)
        for item in values {
            appendString(item, to: &data)
        }
    }

    struct BinaryReader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset + 1 <= data.endIndex else {
                throw Bento7zError.invalidResponse("Truncated binary frame (u8)")
            }
            let value = data[offset]
            offset += 1
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.endIndex else {
                throw Bento7zError.invalidResponse("Truncated binary frame (u32)")
            }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1]) << 8
            let b2 = UInt32(data[offset + 2]) << 16
            let b3 = UInt32(data[offset + 3]) << 24
            offset += 4
            return b0 | b1 | b2 | b3
        }

        mutating func readUInt64() throws -> UInt64 {
            guard offset + 8 <= data.endIndex else {
                throw Bento7zError.invalidResponse("Truncated binary frame (u64)")
            }
            var value: UInt64 = 0
            for i in 0..<8 {
                value |= UInt64(data[offset + i]) << (UInt64(i) * 8)
            }
            offset += 8
            return value
        }

        mutating func readInt64() throws -> Int64 {
            Int64(bitPattern: try readUInt64())
        }

        mutating func readString() throws -> String {
            let len = Int(try readUInt32())
            guard len >= 0, offset + len <= data.endIndex else {
                throw Bento7zError.invalidResponse("Truncated binary frame (string)")
            }
            let slice = data[offset..<(offset + len)]
            offset += len
            return String(decoding: slice, as: UTF8.self)
        }
    }
}
