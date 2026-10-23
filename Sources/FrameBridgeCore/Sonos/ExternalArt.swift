import Foundation

enum ExternalArtError: Error {
    case notAllowed, redirectRefused, notImage, tooLarge, status(Int), unreachable
}

/// Now-playing art hosted off the speaker (Apple Music radio). Only https `mzstatic.com` and its
/// subdomains are ever fetched. URLs are private: they never go in errors or logs.
enum ExternalArt {
    static let maxBytes = 5_000_000
    static let timeout: TimeInterval = 10

    static func allowedURL(_ string: String) -> URL? {
        guard let parts = URLComponents(string: string), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
        else { return nil }
        return parts.url
    }

    static func check(status: Int, mimeType: String?, finalURL: URL?, byteCount: Int) throws {
        guard (200..<300).contains(status) else { throw ExternalArtError.status(status) }
        guard let finalURL, allowedURL(finalURL.absoluteString) != nil else { throw ExternalArtError.redirectRefused }
        guard mimeType?.lowercased().hasPrefix("image/") == true else { throw ExternalArtError.notImage }
        guard byteCount <= maxBytes else { throw ExternalArtError.tooLarge }
    }
}

protocol ExternalArtTransport: Sendable {
    func get(_ url: URL) async throws -> Data
}

/// No cookies, credentials or cache. A redirect is followed only to another allowed URL.
final class URLSessionExternalArtTransport: ExternalArtTransport, Sendable {
    private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            request.url.flatMap { ExternalArt.allowedURL($0.absoluteString) } == nil ? nil : request
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
        }
    }

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = ExternalArt.timeout
        configuration.timeoutIntervalForResource = ExternalArt.timeout
        session = URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
    }

    func get(_ url: URL) async throws -> Data {
        guard ExternalArt.allowedURL(url.absoluteString) != nil else { throw ExternalArtError.notAllowed }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw ExternalArtError.unreachable }
            try ExternalArt.check(status: http.statusCode, mimeType: http.mimeType, finalURL: http.url, byteCount: 0)
            if response.expectedContentLength > Int64(ExternalArt.maxBytes) { throw ExternalArtError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ExternalArt.maxBytes { throw ExternalArtError.tooLarge }
            }
            return data
        } catch let error as ExternalArtError {
            throw error
        } catch let error as URLError where error.code == .httpTooManyRedirects || error.code == .cancelled {
            throw ExternalArtError.redirectRefused
        } catch {
            throw ExternalArtError.unreachable
        }
    }
}
