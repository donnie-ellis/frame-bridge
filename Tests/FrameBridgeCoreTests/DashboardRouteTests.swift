import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

private func makeApp(_ dir: DashboardTestDir) -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config(dashboardDir: dir.dist.path)))
}

@Test func filesNeedTheCookie() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    try await makeApp(dir).test(.router) { client in
        try await client.execute(uri: "/", method: .get) { response in
            #expect(response.status == .unauthorized)
            let body = String(buffer: response.body)
            #expect(body.contains("unauthorized"))
            #expect(!body.contains(DashboardTestDir.indexMarker))
            #expect(!body.contains("<html"))
        }
    }
}

@Test func servesIndexWithCacheControlByPath() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    try await makeApp(dir).test(.router) { client in
        try await client.execute(uri: "/", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body).contains(DashboardTestDir.indexMarker))
            #expect(response.headers[.cacheControl] == "no-cache")
        }
        try await client.execute(uri: "/index.html", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "no-cache")
        }
        try await client.execute(uri: "/assets/app-abc123.js", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == "public, max-age=31536000, immutable")
        }
    }
}

@Test func unknownApiPathsAreJsonNotFound() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    try await makeApp(dir).test(.router) { client in
        for (uri, method) in [("/api/nope", HTTPRequest.Method.get), ("/api/nope", .put), ("/api", .get)] {
            try await client.execute(uri: uri, method: method, headers: TestAuth.headers) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[.contentType] == "application/json")
                let body = String(buffer: response.body)
                #expect(body.contains("\"not_found\""))
                #expect(!body.contains("null"))
            }
        }
    }
}

@Test func missingAndEscapingPathsAreNotFound() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    try await makeApp(dir).test(.router) { client in
        for uri in ["/missing.js", "/../secret.txt", "/%2e%2e/secret.txt", "/link.txt"] {
            try await client.execute(uri: uri, method: .get, headers: TestAuth.headers) { response in
                #expect(response.status == .notFound)
                #expect(!String(buffer: response.body).contains(DashboardTestDir.secret))
            }
        }
    }
}

@Test func routeBeatsSameNamedFile() async throws {
    let dir = try DashboardTestDir()
    defer { dir.remove() }
    try await makeApp(dir).test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get, headers: TestAuth.headers) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.cacheControl] == nil)
            _ = try JSONDecoder().decode(Health.self, from: Data(String(buffer: response.body).utf8))
        }
    }
}
