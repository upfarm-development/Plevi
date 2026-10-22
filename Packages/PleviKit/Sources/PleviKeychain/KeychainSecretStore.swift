import Foundation
import Security

public struct KeychainError: Error, Sendable {
    public let status: OSStatus
    public let operation: String

    public var message: String {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(detail)"
    }
}

/// Keychain-backed secret storage.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func secret(for key: SecretKey) throws -> Data? {
        var query = baseQuery(for: key)
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
            throw KeychainError(status: status, operation: "read")
        }
    }

    public func setSecret(_ data: Data, for key: SecretKey) throws {
        var attributes = baseQuery(for: key)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError(status: updateStatus, operation: "update")
            }
        default:
            throw KeychainError(status: addStatus, operation: "add")
        }
    }

    public func removeSecret(for key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    public func removeSecrets(accountPrefix prefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SecretKey.defaultService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix(prefix)
                else { continue }
                try removeSecret(for: SecretKey(account: account))
            }
        case errSecItemNotFound:
            return
        default:
            throw KeychainError(status: status, operation: "enumerate")
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
    }
}
