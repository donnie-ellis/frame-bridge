import CryptoKit
import Foundation
import HTTPTypes

@testable import FrameBridgeCore

enum TestAuth {
    static func hex(sha256 token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let token = UUID().uuidString + UUID().uuidString
    static var config: Config { Config(frames: ["kitchen": hex(sha256: token)]) }
    static var headers: HTTPFields { [.cookie: "frame_token=\(token)"] }
}
