import Foundation
import Security

/// Minimal secret storage keyed by account name. `KeychainStore` is the real implementation;
/// tests substitute an in-memory fake (SPM test bundles have no keychain-access-group entitlement).
public protocol SecretStoring: Sendable {
    func setData(_ data: Data, account: String) throws
    func data(account: String) throws -> Data?
    func delete(account: String) throws
}

/// Keychain generic passwords per docs/ARCHITECTURE.md §5: service `io.github.rkceve.skipass`,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. The access group defaults
/// to the one resolved and verified at runtime (`SharedStorageEnvironment.current`); nil omits
/// `kSecAttrAccessGroup`, so the process's default group is used (app-only fallback).
public struct KeychainStore: SecretStoring {
    public let service: String
    public let accessGroup: String?

    public init(service: String = StorageConstants.keychainService,
                accessGroup: String? = SharedStorageEnvironment.current.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func setData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addQuery = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StorageError.keychain(status: addStatus) }
        default:
            throw StorageError.keychain(status: updateStatus)
        }
    }

    public func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw StorageError.keychain(status: status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        // Use the iOS-style data protection keychain on macOS so access groups behave the same.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
