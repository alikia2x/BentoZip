import Foundation

/// Domain errors returned by the `bento7z` archive engine.
public enum Bento7zError: LocalizedError, Equatable {
    case binaryNotFound(String)
    case processError(String)
    case invalidResponse(String)
    case operationFailed(String, String)
    case fileNotFound(String)
    case missingVolume(String)
    case splitNotFirstVolume(String)
    case corruptArchive(String)
    case conflict(String)
    case passwordRequired
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return String(localized: "Archive engine not found: \(path)", bundle: .module)
        case .processError(let detail):
            return String(localized: "Engine process error: \(detail)", bundle: .module)
        case .invalidResponse(let detail):
            return String(localized: "Invalid engine response: \(detail)", bundle: .module)
        case .operationFailed(let message, let code):
            return String(localized: "Operation failed [\(code)]: \(message)", bundle: .module)
        case .fileNotFound(let path):
            return String(localized: "File not found: \(path)", bundle: .module)
        case .missingVolume(let detail):
            return detail
        case .splitNotFirstVolume(let detail):
            return detail
        case .corruptArchive(let detail):
            return detail
        case .conflict(let detail):
            return detail
        case .passwordRequired:
            return String(localized: "This archive is password protected.", bundle: .module)
        case .wrongPassword:
            return String(localized: "Incorrect password. Please try again.", bundle: .module)
        }
    }

    static func mapError(code: String, message: String) -> Bento7zError {
        if code == "PASSWORD_REQUIRED" {
            return .passwordRequired
        }
        if code == "WRONG_PASSWORD" {
            return .wrongPassword
        }
        if code == "CORRUPT_ARCHIVE" {
            let detail = message.isEmpty
                ? String(localized: "The archive appears to be corrupt or incomplete.", bundle: .module)
                : message
            return .corruptArchive(detail)
        }
        if code == "CONFLICT" || code == "ALREADY_EXISTS" {
            let detail = message.isEmpty
                ? String(localized: "Destination already exists.", bundle: .module)
                : message
            return .conflict(detail)
        }
        if code == "MISSING_VOLUME" {
            let prefix = "Missing archive volume: "
            let volumeName = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
            return .missingVolume(String(localized: "Missing archive volume: \(volumeName). Keep all split parts in the same folder.", bundle: .module))
        }
        if code == "SPLIT_NOT_FIRST_VOLUME" {
            return .splitNotFirstVolume(String(localized: "Open the first volume (.001 or .part1.rar) of a split archive.", bundle: .module))
        }

        let lower = message.lowercased()
        if code == "BIT7Z_ERROR" || lower.contains("password") || lower.contains("encrypted") {
            if lower.contains("wrong password")
                || lower.contains("incorrect password")
                || lower.contains("invalid password")
                || lower.contains("bad password") {
                return .wrongPassword
            }
            if lower.contains("password") || lower.contains("encrypted") {
                return .passwordRequired
            }
        }

        return .operationFailed(message, code)
    }
}
