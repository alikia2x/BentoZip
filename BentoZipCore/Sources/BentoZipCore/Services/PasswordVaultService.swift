import Foundation
import LocalAuthentication
import os
import Security

/// A saved archive password entry stored in the Keychain password vault.
public struct PasswordVaultEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var label: String
    public var password: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        password: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.password = password
        self.createdAt = createdAt
    }
}

/// Cryptographically secure password generator backed by `SecRandomCopyBytes`.
public enum PasswordGenerator: Sendable {
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")
    private static let symbols = Array("!@#$%^&*()-_=+[]{}|;:,.<>?")

    /// Generate a random password of `length` characters using `SecRandomCopyBytes`.
    public static func generate(length: Int = 20, includeSymbols: Bool = true) -> String {
        guard length > 0 else { return "" }

        var buckets: [[Character]] = [lowercase, uppercase, digits]
        if includeSymbols {
            buckets.append(symbols)
        }
        let allChars = buckets.flatMap { $0 }

        var result: [Character] = []
        result.reserveCapacity(length)

        // Ensure at least one character from each enabled class when length allows.
        if length >= buckets.count {
            for bucket in buckets {
                result.append(bucket[randomIndex(upperBound: bucket.count)])
            }
        }

        while result.count < length {
            result.append(allChars[randomIndex(upperBound: allChars.count)])
        }

        // Fisher-Yates shuffle using SecRandomCopyBytes.
        if result.count > 1 {
            for i in stride(from: result.count - 1, through: 1, by: -1) {
                let j = randomIndex(upperBound: i + 1)
                if i != j {
                    result.swapAt(i, j)
                }
            }
        }

        return String(result)
    }

    private static func randomIndex(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        let bound = UInt32(upperBound)
        let limit = UInt32.max - (UInt32.max % bound)
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { buffer in
                guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
            }
            if status == errSecSuccess {
                if value < limit {
                    return Int(value % bound)
                }
            } else {
                // Fallback to SystemRandomNumberGenerator if SecRandomCopyBytes is unexpectedly unavailable.
                return Int.random(in: 0..<upperBound)
            }
        }
    }
}

/// Errors surfaced when reading or persisting entries in the Keychain password vault.
public enum PasswordVaultError: LocalizedError, Sendable, Equatable {
    case encodingFailed
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "Failed to encode password vault entries.", bundle: .module)
        case .keychainError(let status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return String(localized: "Keychain operation failed: \(message) (\(status))", bundle: .module)
        }
    }
}

/// Manages saved archive passwords in the macOS Keychain (or an isolated in-memory store for unit tests),
/// with optional Touch ID / device-owner biometric authentication.
public final class PasswordVaultService: @unchecked Sendable {
    public static let shared = PasswordVaultService()

    public static let defaultService = "com.bentozip.password-vault"
    public static let defaultAccount = "vault-entries"
    private static let logger = Logger(subsystem: "com.bentozip.core", category: "PasswordVault")

    private enum StorageMode {
        case keychain(service: String, account: String)
        case inMemory
    }

    private struct VaultState {
        var entries: [PasswordVaultEntry]
        var lastStatus: OSStatus = errSecSuccess
        var lastErrorMessage: String?
    }

    private let mode: StorageMode
    private let lock: OSAllocatedUnfairLock<VaultState>

    /// Most recent Keychain `OSStatus` recorded by this vault instance.
    public var lastKeychainStatus: OSStatus {
        lock.withLock { $0.lastStatus }
    }

    /// Most recent Keychain error message recorded by this vault instance, if any.
    public var lastError: String? {
        lock.withLock { $0.lastErrorMessage }
    }

    /// Create a Keychain-backed password vault service.
    public init(
        service: String = PasswordVaultService.defaultService,
        account: String = PasswordVaultService.defaultAccount
    ) {
        self.mode = .keychain(service: service, account: account)
        self.lock = OSAllocatedUnfairLock(initialState: VaultState(entries: []))
    }

    /// Create an isolated in-memory vault for unit tests without touching the user's Keychain.
    public init(inMemoryEntries: [PasswordVaultEntry]) {
        self.mode = .inMemory
        self.lock = OSAllocatedUnfairLock(initialState: VaultState(entries: inMemoryEntries))
    }

    /// Convenience factory for an isolated in-memory vault in tests.
    public static func inMemory(_ entries: [PasswordVaultEntry] = []) -> PasswordVaultService {
        PasswordVaultService(inMemoryEntries: entries)
    }

    /// Load all saved vault entries.
    public func loadEntries() -> [PasswordVaultEntry] {
        switch mode {
        case .inMemory:
            return lock.withLock { $0.entries }
        case .keychain(let service, let account):
            return lock.withLock { state in
                let result = readKeychainEntries(service: service, account: account)
                state.lastStatus = result.status
                state.lastErrorMessage = result.errorMessage
                return result.entries
            }
        }
    }

    /// Return all non-empty saved passwords in stored order (deduplicated).
    public func allPasswords() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in loadEntries() where !entry.password.isEmpty {
            if seen.insert(entry.password).inserted {
                result.append(entry.password)
            }
        }
        return result
    }

    /// Add a new password entry to the vault and persist it, throwing on Keychain write failure.
    @discardableResult
    public func saveEntry(label: String, password: String) throws -> PasswordVaultEntry {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = PasswordVaultEntry(
            label: trimmedLabel.isEmpty ? "Untitled" : trimmedLabel,
            password: password
        )
        switch mode {
        case .inMemory:
            lock.withLock { state in
                state.entries.append(entry)
                state.lastStatus = errSecSuccess
                state.lastErrorMessage = nil
            }
        case .keychain(let service, let account):
            try lock.withLock { state in
                var entries = readKeychainEntries(service: service, account: account).entries
                entries.append(entry)
                do {
                    try writeKeychainEntries(entries, service: service, account: account)
                    state.lastStatus = errSecSuccess
                    state.lastErrorMessage = nil
                } catch let error as PasswordVaultError {
                    if case .keychainError(let status) = error {
                        state.lastStatus = status
                    }
                    state.lastErrorMessage = error.localizedDescription
                    Self.logger.error("Failed to persist vault entry: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        }
        return entry
    }

    /// Add a new password entry to the vault and persist it (recording any Keychain error in `lastError`).
    @discardableResult
    public func addEntry(label: String, password: String) -> PasswordVaultEntry {
        do {
            return try saveEntry(label: label, password: password)
        } catch {
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return PasswordVaultEntry(
                label: trimmedLabel.isEmpty ? "Untitled" : trimmedLabel,
                password: password
            )
        }
    }

    /// Delete the entry matching `id` from the vault, throwing on Keychain write failure.
    public func removeEntry(id: UUID) throws {
        switch mode {
        case .inMemory:
            lock.withLock { state in
                state.entries.removeAll { $0.id == id }
                state.lastStatus = errSecSuccess
                state.lastErrorMessage = nil
            }
        case .keychain(let service, let account):
            try lock.withLock { state in
                var entries = readKeychainEntries(service: service, account: account).entries
                entries.removeAll { $0.id == id }
                do {
                    try writeKeychainEntries(entries, service: service, account: account)
                    state.lastStatus = errSecSuccess
                    state.lastErrorMessage = nil
                } catch let error as PasswordVaultError {
                    if case .keychainError(let status) = error {
                        state.lastStatus = status
                    }
                    state.lastErrorMessage = error.localizedDescription
                    Self.logger.error("Failed to remove vault entry: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        }
    }

    /// Delete the entry matching `id` from the vault (recording any Keychain error in `lastError`).
    public func deleteEntry(id: UUID) {
        try? removeEntry(id: id)
    }

    /// Check whether `password` is already stored in the vault.
    public func contains(password: String) -> Bool {
        guard !password.isEmpty else { return false }
        return loadEntries().contains { $0.password == password }
    }

    /// Authenticate the user with Touch ID / Apple Watch (falling back to macOS account password when available).
    public func authenticateWithBiometrics(reason: String) async -> Bool {
        let context = LAContext()
        var authError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &authError) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - Keychain Persistence

    private func readKeychainEntries(
        service: String,
        account: String
    ) -> (entries: [PasswordVaultEntry], status: OSStatus, errorMessage: String?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ([], errSecSuccess, nil)
        }
        guard status == errSecSuccess else {
            let err = PasswordVaultError.keychainError(status)
            Self.logger.warning("Keychain read failed: \(err.localizedDescription, privacy: .public)")
            return ([], status, err.localizedDescription)
        }
        guard let data = result as? Data else {
            return ([], errSecSuccess, nil)
        }
        let decoded = (try? JSONDecoder().decode([PasswordVaultEntry].self, from: data)) ?? []
        return (decoded, errSecSuccess, nil)
    }

    private func writeKeychainEntries(
        _ entries: [PasswordVaultEntry],
        service: String,
        account: String
    ) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(entries)
        } catch {
            throw PasswordVaultError.encodingFailed
        }

        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        let attributesToUpdate: [CFString: Any] = [
            kSecValueData: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PasswordVaultError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw PasswordVaultError.keychainError(updateStatus)
        }
    }
}
