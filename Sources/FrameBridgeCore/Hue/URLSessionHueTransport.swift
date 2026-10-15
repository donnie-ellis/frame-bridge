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
final class URLSessionHueTransport: HueTransport, HueEventStreamTransport, Sendable {
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

    /// The event stream lives at `/eventstream/clip/v2`, not under `/clip/v2/`. Chunks are one
    /// line each: `.lines` would drop the blank lines that end a message.
    func eventStream() async throws -> AsyncThrowingStream<Data, any Error> {
        guard let url = URL(string: "https://\(bridge)/eventstream/clip/v2") else { throw HueClientError.unreachable }
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is URLError {
            throw HueClientError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw HueClientError.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw HueClientError.unauthorized
        default: throw HueClientError.status(http.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line = Data()
                        }
                    }
                    continuation.finish()
                } catch is URLError {
                    continuation.finish(throwing: HueClientError.unreachable)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
