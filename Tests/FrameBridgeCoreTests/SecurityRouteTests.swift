import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import FrameBridgeCore

private let hue = HueConfig(bridge: "bridge.invalid", sceneIcons: HueFixture.icons)

private func lightsApp(_ fake: FakeHueTransport) -> some ApplicationProtocol {
    let feed = LightsFeed(config: hue, client: HueClient(transport: fake), logger: Logger(label: "test"))
    return Application(router: buildRouter(config: TestAuth.config, lights: feed))
}

private func expectHeaders(_ headers: HTTPFields) {
    #expect(headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
    #expect(headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
    #expect(headers[HTTPField.Name("X-Frame-Options")!] == "DENY")
    #expect(headers[HTTPField.Name("Content-Security-Policy")!] == "frame-ancestors 'none'; object-src 'none'; base-uri 'none'")
}

private func headers(origin: String?, cookie: Bool = true) -> HTTPFields {
    var h = cookie ? TestAuth.headers : HTTPFields()
    if let origin { h[.origin] = origin }
    return h
}

@Test func securityHeadersOnEveryKindOfResponse() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    let app = Application(router: buildRouter(config: TestAuth.config(dashboardDir: dir.dist.path)))
    try await app.test(.router) { client in
        for (uri, method, h, status) in [
            ("/healthz", HTTPRequest.Method.get, TestAuth.headers, HTTPResponse.Status.ok),
            ("/", .get, TestAuth.headers, .ok),
            ("/healthz", .get, HTTPFields(), .unauthorized),
            ("/api/nope", .get, TestAuth.headers, .notFound),
            ("/api/weather", .get, TestAuth.headers, .serviceUnavailable),
            ("/api/lights/x", .put, TestAuth.headers, .serviceUnavailable),
        ] {
            try await client.execute(uri: uri, method: method, headers: h) { response in
                #expect(response.status == status)
                expectHeaders(response.headers)
            }
        }
    }
}

@Test func badBodyErrorAlsoGetsHeaders() async throws {
    let fake = FakeHueTransport()
    try await lightsApp(fake).test(.router) { client in
        try await client.execute(uri: "/api/lights/\(HueFixture.light(1))", method: .put, headers: TestAuth.headers, body: ByteBuffer(string: #"{"level":0}"#)) { response in
            #expect(response.status == .badRequest)
            expectHeaders(response.headers)
        }
    }
}

@Test func writesWithSameOriginOrNoOriginPass() async throws {
    let fake = FakeHueTransport()
    try await lightsApp(fake).test(.router) { client in
        for origin in [nil, "http://localhost", "HTTP://LOCALHOST"] {
            try await client.execute(uri: "/api/lights/\(HueFixture.light(2))", method: .put, headers: headers(origin: origin), body: ByteBuffer(string: #"{"on":true}"#)) { response in
                #expect(response.status == .ok)
            }
        }
    }
}

@Test func foreignOriginWriteIs403AndNothingIsSent() async throws {
    let fake = FakeHueTransport()
    try await lightsApp(fake).test(.router) { client in
        for origin in ["http://evil.invalid", "null"] {
            try await client.execute(uri: "/api/lights/\(HueFixture.light(2))", method: .put, headers: headers(origin: origin), body: ByteBuffer(string: #"{"on":true}"#)) { response in
                #expect(response.status == .forbidden)
                #expect(String(buffer: response.body) == #"{"error":"forbidden"}"#)
                expectHeaders(response.headers)
            }
        }
        try await client.execute(uri: "/api/scenes/x/recall", method: .post, headers: headers(origin: "http://evil.invalid")) { response in
            #expect(response.status == .forbidden)
        }
    }
    #expect(await fake.recorded().filter { $0.method == "PUT" }.isEmpty)
}

@Test func foreignOriginWithoutCookieIs401() async throws {
    let fake = FakeHueTransport()
    try await lightsApp(fake).test(.router) { client in
        try await client.execute(uri: "/api/lights/\(HueFixture.light(2))", method: .put, headers: headers(origin: "http://evil.invalid", cookie: false), body: ByteBuffer(string: #"{"on":true}"#)) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func getWithForeignOriginStillWorks() async throws {
    let app = Application(router: buildRouter(config: TestAuth.config))
    try await app.test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get, headers: headers(origin: "http://evil.invalid")) { response in
            #expect(response.status == .ok)
        }
    }
}

@Test func isAllowedRules() {
    typealias M = OriginCheckMiddleware
    #expect(M.isAllowed(method: .get, origin: "http://evil.invalid", host: "a"))
    #expect(M.isAllowed(method: .put, origin: nil, host: "a"))
    #expect(M.isAllowed(method: .put, origin: "http://192.0.2.1:8787", host: "192.0.2.1:8787"))
    #expect(!M.isAllowed(method: .put, origin: "https://192.0.2.1:8787", host: "192.0.2.1:8787"))
    #expect(!M.isAllowed(method: .put, origin: "http://a", host: nil))
    #expect(!M.isAllowed(method: .head, origin: "http://evil.invalid", host: "a"))
}
