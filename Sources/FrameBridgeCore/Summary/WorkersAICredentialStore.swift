import Foundation
import Security

/// The Cloudflare account id and the Workers AI API token. Never print these.
struct WorkersAICredentials: Sendable {
    let accountId: String
    let token: String
}

/// Read only: the owner puts the items in the Keychain by hand (README).
protocol WorkersAICredentialStore: Sendable {
    func load() throws -> WorkersAICredentials?
}

/// Login Keychain, generic passwords. Tests never construct this.
struct KeychainWorkersAICredentialStore: WorkersAICredentialStore {
    static let service = "local.frame-bridge.workers-ai"
    static let accountIdAccount = "account-id"
    static let tokenAccount = "api-token"

    init() {}

    func load() throws -> WorkersAICredentials? {
        guard let id = try read(Self.accountIdAccount), let token = try read(Self.tokenAccount) else { return nil }
        // The id goes into a URL path: anything but 32 lowercase hex characters is treated as missing.
        guard id.utf8.count == 32, id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return WorkersAICredentials(accountId: id, token: token)
    }

    /// Trimmed. Nil when the item is missing or empty.
    private func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
