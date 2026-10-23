import Foundation
import Testing

@testable import FrameBridgeCore

/// Answers from a lock-protected handler; never touches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)
    private static let state = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var seen: [URL] = []

    static func install(_ h: @escaping Handler) { state.withLock { handler = h; seen = [] } }
    static var requests: [URL] { state.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let h = Self.state.withLock { () -> Handler? in Self.seen.append(request.url!); return Self.handler }
        guard let h else { return }
        let r = h(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        if (300..<400).contains(r.status), let location = r.headers["Location"], let to = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private let artURL = URL(string: "https://is1-ssl.mzstatic.com/image/a.jpg")!

private func transport() -> URLSessionExternalArtTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionExternalArtTransport(configuration: configuration)
}

@Suite(.serialized) struct ExternalArtFetcherTests {
    @Test func acceptsASmallImage() async throws {
        let jpeg = try SonosFixture.data("art", ext: "jpg")
        StubURLProtocol.install { _ in (200, ["Content-Type": "image/jpeg"], jpeg) }
        #expect(try await transport().get(artURL) == jpeg)
    }

    @Test func followsARedirectToAnotherAllowedSubdomain() async throws {
        let jpeg = try SonosFixture.data("art", ext: "jpg")
        StubURLProtocol.install { r in
            r.url!.host == "is1-ssl.mzstatic.com"
                ? (302, ["Location": "https://is2-ssl.mzstatic.com/b.jpg"], Data())
                : (200, ["Content-Type": "image/jpeg"], jpeg)
        }
        #expect(try await transport().get(artURL) == jpeg)
    }

    @Test func refusesARedirectOffTheAllowedHost() async {
        StubURLProtocol.install { _ in (302, ["Location": "https://example.com/a.jpg"], Data()) }
        await #expect(throws: ExternalArtError.self) { try await transport().get(artURL) }
        #expect(!StubURLProtocol.requests.contains { $0.host == "example.com" })
    }

    @Test func refusesNonImages() async {
        StubURLProtocol.install { _ in (200, ["Content-Type": "text/html"], Data("<html>".utf8)) }
        await #expect(throws: ExternalArtError.self) { try await transport().get(artURL) }
    }

    @Test func refusesOversizedBodies() async {
        let big = Data(count: ExternalArt.maxBytes + 1)
        StubURLProtocol.install { _ in (200, ["Content-Type": "image/jpeg", "Content-Length": "\(big.count)"], big) }
        await #expect(throws: ExternalArtError.self) { try await transport().get(artURL) }
        StubURLProtocol.install { _ in (200, ["Content-Type": "image/jpeg"], big) }
        await #expect(throws: ExternalArtError.self) { try await transport().get(artURL) }
    }

    @Test func nonAllowedURLIsNeverRequested() async {
        StubURLProtocol.install { _ in (200, ["Content-Type": "image/jpeg"], Data()) }
        await #expect(throws: ExternalArtError.self) { try await transport().get(URL(string: "https://example.com/a.jpg")!) }
        #expect(StubURLProtocol.requests.isEmpty)
    }
}

@Test func checkRules() {
    let ok = artURL
    #expect(throws: Never.self) { try ExternalArt.check(status: 200, mimeType: "image/png", finalURL: ok, byteCount: 10) }
    #expect(throws: ExternalArtError.self) { try ExternalArt.check(status: 404, mimeType: "image/png", finalURL: ok, byteCount: 10) }
    #expect(throws: ExternalArtError.self) { try ExternalArt.check(status: 200, mimeType: "text/html", finalURL: ok, byteCount: 10) }
    #expect(throws: ExternalArtError.self) { try ExternalArt.check(status: 200, mimeType: nil, finalURL: ok, byteCount: 10) }
    #expect(throws: ExternalArtError.self) { try ExternalArt.check(status: 200, mimeType: "image/png", finalURL: URL(string: "https://example.com/a")!, byteCount: 10) }
    #expect(throws: ExternalArtError.self) { try ExternalArt.check(status: 200, mimeType: "image/png", finalURL: ok, byteCount: ExternalArt.maxBytes + 1) }
}
