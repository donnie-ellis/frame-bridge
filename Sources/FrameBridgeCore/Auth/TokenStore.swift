import CryptoKit
import Foundation

/// Holds one SHA-256 digest per frame. Tokens themselves are never stored.
public struct TokenStore: Sendable {
    private let entries: [(name: String, digest: [UInt8])]

    public init(hashes: [String: String]) {
        entries = hashes.sorted { $0.key < $1.key }.map { ($0.key, Self.bytes(fromHex: $0.value)) }
    }

    public init(config: Config) {
        self.init(hashes: config.frames)
    }

    /// Checks every entry with no early exit, so timing doesn't reveal which frame matched.
    public func frameName(forToken token: String) -> String? {
        if token.isEmpty { return nil }
        let presented = Array(SHA256.hash(data: Data(token.utf8)))
        var match: String?
        for entry in entries {
            var diff: UInt8 = entry.digest.count == 32 ? 0 : 1
            for i in 0..<32 {
                let stored: UInt8 = i < entry.digest.count ? entry.digest[i] : 0
                diff |= presented[i] ^ stored
            }
            if diff == 0 { match = entry.name }
        }
        return match
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        let chars = Array(hex.utf8)
        var out: [UInt8] = []
        var i = 0
        while i + 1 < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return [] }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }
}
