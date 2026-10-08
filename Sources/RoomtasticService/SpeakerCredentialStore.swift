// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import CryptoKit
import RoomtasticControl

/// Secrets never enter saved room/preset JSON or service status responses.
enum SpeakerCredentialStore {
    private static let service = "org.roomtastic.airplay-receivers"
    static func identity(outputID: String) -> String {
        SHA256.hash(data: Data(outputID.utf8)).prefix(8).map { String(format: "%02X", $0) }.joined()
    }
    static func load(outputID: String) throws -> ReceiverCredentials? {
        var query = query(outputID)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(ReceiverCredentials.self, from: data)
    }
    static func save(outputID: String, credentials: ReceiverCredentials) throws {
        guard outputID.hasPrefix("airplay:"), outputID.utf8.count <= 128 else { throw AudioFailure("Invalid receiver identifier") }
        let values = [credentials.password, credentials.auth, credentials.legacySecret].compactMap { $0 }
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) else { throw AudioFailure("Enter receiver credentials before saving") }
        if let auth = credentials.auth { guard auth.count == 192, auth.allSatisfy(\.isHexDigit) else { throw AudioFailure("AirPlay 2 pairing credentials must contain 192 hexadecimal characters") } }
        let data = try JSONEncoder().encode(credentials)
        let update = SecItemUpdate(query(outputID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query(outputID); item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if update != errSecSuccess { throw keychainError(update) }
    }
    static func remove(outputID: String) throws {
        let status = SecItemDelete(query(outputID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    private static func keychainError(_ status: OSStatus) -> AudioFailure {
        AudioFailure("Receiver Keychain operation failed (\(status))")
    }
}
