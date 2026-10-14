import Foundation
import os
import Security

enum PairingResult: Equatable {
    case paired(key: String)
    case linkButtonNotPressed
    case failed(String)
}

enum HuePairing {
    static func pairingRequestBody() -> Data {
        Data(#"{"devicetype":"frame-bridge#macmini","generateclientkey":true}"#.utf8)
    }

    /// `[{"success":{"username":K}}]` or `[{"error":{"type":N}}]`.
    static func parseResponse(_ data: Data) -> PairingResult {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let first = array.first else {
            return .failed("unexpected response")
        }
        if let success = first["success"] as? [String: Any], let key = success["username"] as? String, !key.isEmpty {
            return .paired(key: key)
        }
        if let error = first["error"] as? [String: Any] {
            if (error["type"] as? Int) == 101 { return .linkButtonNotPressed }
            return .failed("bridge refused pairing")
        }
        return .failed("unexpected response")
    }
}

struct HuePairingError: Error, CustomStringConvertible {
    let description: String
}

/// Records the leaf cert's SHA-256 and cancels, so nothing is sent before the user trusts it.
private final class CapturingCertificateDelegate: NSObject, URLSessionDelegate, Sendable {
    private let der = OSAllocatedUnfairLock<Data?>(initialState: nil)
    var captured: Data? { der.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            let leaf = leafDER(of: trust)
            der.withLock { $0 = leaf }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

/// Trust on first use: shows the bridge's certificate fingerprint, asks, then pairs over a
/// connection pinned to it. Prints no key.
public func runHuePairing(bridge: String, prompt: @Sendable (String) -> String?) async throws {
    try await runHuePairing(bridge: bridge, store: KeychainHueCredentialStore(), prompt: prompt)
}

func runHuePairing(bridge: String, store: any HueCredentialStore, prompt: @Sendable (String) -> String?) async throws {
    guard HueConfig.isValidHost(bridge), let probeURL = URL(string: "https://\(bridge)/api/0/config"), let pairURL = URL(string: "https://\(bridge)/api") else {
        throw HuePairingError(description: "bridge must be a host name or IP")
    }
    let capture = CapturingCertificateDelegate()
    let probe = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
    _ = try? await probe.data(for: URLRequest(url: probeURL, timeoutInterval: 10))
    guard let der = capture.captured else { throw HuePairingError(description: "could not reach the bridge") }
    let pin = CertificatePin.sha256Hex(der)
    let colons = stride(from: 0, to: pin.count, by: 2).map { i -> String in
        let a = pin.index(pin.startIndex, offsetBy: i)
        return String(pin[a..<pin.index(a, offsetBy: 2)])
    }.joined(separator: ":")
    print("Bridge certificate SHA-256: \(colons)")
    let answer = prompt("Trust this certificate? [y/N] ")?.trimmingCharacters(in: .whitespaces).lowercased()
    guard answer == "y" || answer == "yes" else { throw HuePairingError(description: "not trusted, nothing stored") }

    let session = URLSession(configuration: .ephemeral, delegate: PinnedCertificateDelegate(pin: pin), delegateQueue: nil)
    var attempts = 0
    while true {
        _ = prompt("Press the link button on the bridge, then press Enter. ")
        var request = URLRequest(url: pairURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = HuePairing.pairingRequestBody()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        do { data = try await session.data(for: request).0 } catch { throw HuePairingError(description: "could not reach the bridge") }
        switch HuePairing.parseResponse(data) {
        case .paired(let key):
            try store.save(HueCredentials(applicationKey: key, certificateSHA256: pin))
            print("paired; restart frame-bridge")
            return
        case .linkButtonNotPressed:
            attempts += 1
            guard attempts < 2 else { throw HuePairingError(description: "link button was not pressed") }
            print("The link button was not pressed.")
        case .failed(let reason):
            throw HuePairingError(description: reason)
        }
    }
}
