import CryptoKit
import Foundation
import Security

/// Hex SHA-256 of a certificate's DER bytes.
enum CertificatePin {
    static func sha256Hex(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(der: Data, pinHex: String) -> Bool {
        let pin = pinHex.lowercased()
        return !pin.isEmpty && sha256Hex(der) == pin
    }
}

/// The bridge's cert is self-signed, so it's trusted only when its leaf matches the pin.
/// Verification is never switched off.
final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, Sendable {
    let pin: String

    init(pin: String) { self.pin = pin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let der = leafDER(of: trust), CertificatePin.matches(der: der, pinHex: pin) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

func leafDER(of trust: SecTrust) -> Data? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
    return SecCertificateCopyData(leaf) as Data
}

/// The real bridge connection. Tests never construct this.
final class URLSessionHueTransport: HueTransport, Sendable {
    private let bridge: String
    private let applicationKey: String
    private let session: URLSession

    init(bridge: String, applicationKey: String, pin: String) {
        self.bridge = bridge
        self.applicationKey = applicationKey
        self.session = URLSession(configuration: .ephemeral, delegate: PinnedCertificateDelegate(pin: pin), delegateQueue: nil)
    }

    func send(method: String, path: String, body: Data?) async throws -> (status: Int, data: Data) {
        guard let url = URL(string: "https://\(bridge)/clip/v2/\(path)") else { throw HueClientError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HueClientError.badResponse }
            return (http.statusCode, data)
        } catch is URLError {
            throw HueClientError.unreachable
        }
    }
}
