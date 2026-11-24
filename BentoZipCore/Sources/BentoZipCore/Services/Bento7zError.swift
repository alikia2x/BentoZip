import Foundation

/// Domain errors returned by the `bento7z` archive engine.
public enum Bento7zError: LocalizedError, Equatable {
    case binaryNotFound(String)
    case processError(String)
    case invalidResponse(String)
    case operationFailed(String, String)
    case fileNotFound(String)
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
