import Foundation
import Security

/// The Hue application key and the bridge cert's SHA-256 pin. Never print these.
struct HueCredentials: Sendable {
    let applicationKey: String
    let certificateSHA256: String
}

protocol HueCredentialStore: Sendable {
    func load() throws -> HueCredentials?
    func save(_ credentials: HueCredentials) throws
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "keychain error \(status)" }
}

/// Login Keychain, generic passwords. Tests never construct this.
struct KeychainHueCredentialStore: HueCredentialStore {
    static let service = "local.frame-bridge.hue"
    static let keyAccount = "application-key"
    static let pinAccount = "certificate-sha256"

    init() {}

    func load() throws -> HueCredentials? {
        guard let key = try read(Self.keyAccount), let pin = try read(Self.pinAccount) else { return nil }
        return HueCredentials(applicationKey: key, certificateSHA256: pin)
    }

    func save(_ credentials: HueCredentials) throws {
        try write(Self.keyAccount, credentials.applicationKey)
        try write(Self.pinAccount, credentials.certificateSHA256)
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
