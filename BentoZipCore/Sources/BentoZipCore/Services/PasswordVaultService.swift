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

/// Manages saved archive passwords in the macOS Keychain (or an isolated in-memory store for unit tests),
/// with optional Touch ID / device-owner biometric authentication.
public final class PasswordVaultService: @unchecked Sendable {
    public static let shared = PasswordVaultService()

    public static let defaultService = "com.bentozip.password-vault"
    public static let defaultAccount = "vault-entries"

    private enum StorageMode {
        case keychain(service: String, account: String)
        case inMemory
    }

    private let mode: StorageMode
    private let lock = OSAllocatedUnfairLock(initialState: [PasswordVaultEntry]())

    /// Create a Keychain-backed password vault service.
    public init(
        service: String = PasswordVaultService.defaultService,
        account: String = PasswordVaultService.defaultAccount
    ) {
        self.mode = .keychain(service: service, account: account)
    }

    /// Create an isolated in-memory vault for unit tests without touching the user's Keychain.
    public init(inMemoryEntries: [PasswordVaultEntry]) {
        self.mode = .inMemory
        self.lock.withLock { $0 = inMemoryEntries }
    }

    /// Convenience factory for an isolated in-memory vault in tests.
    public static func inMemory(_ entries: [PasswordVaultEntry] = []) -> PasswordVaultService {
        PasswordVaultService(inMemoryEntries: entries)
    }

    /// Load all saved vault entries.
    public func loadEntries() -> [PasswordVaultEntry] {
        switch mode {
        case .inMemory:
            return lock.withLock { $0 }
        case .keychain(let service, let account):
            return lock.withLock { _ in
                readKeychainEntries(service: service, account: account)
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

    /// Add a new password entry to the vault and persist it.
    @discardableResult
    public func addEntry(label: String, password: String) -> PasswordVaultEntry {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = PasswordVaultEntry(
            label: trimmedLabel.isEmpty ? "Untitled" : trimmedLabel,
            password: password
        )
        switch mode {
        case .inMemory:
            lock.withLock { $0.append(entry) }
        case .keychain(let service, let account):
            lock.withLock { _ in
                var entries = readKeychainEntries(service: service, account: account)
                entries.append(entry)
                writeKeychainEntries(entries, service: service, account: account)
            }
        }
        return entry
    }

    /// Delete the entry matching `id` from the vault.
    public func deleteEntry(id: UUID) {
        switch mode {
        case .inMemory:
            lock.withLock { $0.removeAll { $0.id == id } }
        case .keychain(let service, let account):
            lock.withLock { _ in
                var entries = readKeychainEntries(service: service, account: account)
                entries.removeAll { $0.id == id }
                writeKeychainEntries(entries, service: service, account: account)
            }
        }
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

    private func readKeychainEntries(service: String, account: String) -> [PasswordVaultEntry] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return []
        }
        return (try? JSONDecoder().decode([PasswordVaultEntry].self, from: data)) ?? []
    }

    private func writeKeychainEntries(_ entries: [PasswordVaultEntry], service: String, account: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }

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
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
