import ApronKit
import Foundation
import Security

/// Bearer tokens in the Keychain as generic passwords: service `app.ladle.ios.token`,
/// account = the server's id. The only place a secret is persisted.
struct KeychainStore: TokenStore {
    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    private static let service = "app.ladle.ios.token"

    func token(for serverID: UUID) throws -> String? {
        var query = Self.query(for: serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure(status: status)
        }
    }

    func setToken(_ token: String?, for serverID: UUID) throws {
        let query = Self.query(for: serverID)
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure(status: deleted) }
        guard let token else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    private static func query(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
    }
}
