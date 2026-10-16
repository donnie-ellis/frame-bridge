import CryptoKit
import Foundation
import os
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
final class PinnedCertificateDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let pin: String
    private let lastRejected = OSAllocatedUnfairLock<Bool>(initialState: false)

    init(pin: String) { self.pin = pin }

    var rejectedPin: Bool { lastRejected.withLock { $0 } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    /// `bytes(for:)` (the event stream) sends the server trust challenge only here, never to the
    /// session-level method above: without this the stream fails with -1202.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let der = leafDER(of: trust), CertificatePin.matches(der: der, pinHex: pin) else {
            lastRejected.withLock { $0 = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        lastRejected.withLock { $0 = false }
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
    private let delegate: PinnedCertificateDelegate

    init(bridge: String, applicationKey: String, pin: String) {
        self.bridge = bridge
        self.applicationKey = applicationKey
        self.delegate = PinnedCertificateDelegate(pin: pin)
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    /// The flag reflects the most recent handshake: fine with one bridge cert.
    private func clientError(_ error: URLError) -> HueClientError {
        let tlsCodes: [URLError.Code] = [.cancelled, .secureConnectionFailed, .serverCertificateUntrusted]
        return HueClientError(urlError: error.code, pinRejected: delegate.rejectedPin && tlsCodes.contains(error.code))
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
        } catch let error as URLError {
            throw clientError(error)
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
        } catch let error as URLError {
            throw clientError(error)
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
                } catch let error as URLError {
                    continuation.finish(throwing: self.clientError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
