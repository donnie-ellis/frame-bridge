import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

private func app() -> some ApplicationProtocol {
    Application(router: buildRouter(config: TestAuth.config))
}

@Test func healthzRequiresValidToken() async throws {
    try await app().test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get) { #expect($0.status == .unauthorized) }
        try await client.execute(uri: "/healthz", method: .get, headers: [.cookie: "frame_token=wrong"]) {
            #expect($0.status == .unauthorized)
        }
        try await client.execute(uri: "/healthz", method: .get, headers: [.cookie: "frame_token="]) {
            #expect($0.status == .unauthorized)
        }
        try await client.execute(uri: "/healthz", method: .get, headers: TestAuth.headers) {
            #expect($0.status == .ok)
        }
    }
}

@Test func unauthorizedBodyMatchesSpec() async throws {
    try await app().test(.router) { client in
        try await client.execute(uri: "/healthz", method: .get) { response in
            #expect(response.headers[.contentType] == "application/json")
            let body = String(buffer: response.body)
            #expect(!body.contains("null"))
            #expect(!body.contains("detail"))
            let error = try JSONDecoder().decode(APIError.self, from: Data(body.utf8))
            #expect(error.error == "unauthorized")
            #expect(error.detail == nil)
        }
    }
}

@Test func tokenInQueryOrHeaderIsNotAccepted() async throws {
    try await app().test(.router) { client in
        try await client.execute(uri: "/healthz?frame_token=\(TestAuth.token)", method: .get) {
            #expect($0.status == .unauthorized)
        }
    }
}
