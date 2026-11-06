import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import FrameBridgeCore

private struct FixedGenerator: SummaryGenerating {
    func generate(_ prompt: SummaryPrompt) async throws -> String { "Otto has Pajama Day at school." }
}

private func get(_ summary: SummaryFeed?, _ uri: String = "/api/summary", headers: HTTPFields = TestAuth.headers) async throws -> (status: HTTPResponse.Status, body: String) {
    let app = Application(router: buildRouter(config: TestAuth.config, summary: summary))
    return try await app.test(.router) { client in
        try await client.execute(uri: uri, method: .get, headers: headers) { ($0.status, String(buffer: $0.body)) }
    }
}

private func seeded() async -> SummaryFeed {
    let f = SummaryFeed(calendar: nil, chores: nil, people: [])
    await f.credentialsRead(FixedGenerator())
    await f.generate(now: Date())
    return f
}

@Test func summaryNeedsTheToken() async throws {
    #expect(try await get(await seeded(), headers: [:]).status == .unauthorized)
}

@Test func summaryIs503WhenTheFeedIsMissing() async throws {
    let r = try await get(nil)
    #expect(r.status == .serviceUnavailable)
    let error = try JSONDecoder().decode(APIError.self, from: Data(r.body.utf8))
    #expect(error.error == "source_unavailable" && error.detail == "not configured")
}

@Test func summaryIs503BeforeTheFirstGeneration() async throws {
    let f = SummaryFeed(calendar: nil, chores: nil, people: [])
    await f.credentialsRead(FixedGenerator())
    let r = try await get(f)
    #expect(r.status == .serviceUnavailable)
    #expect(r.body.contains("source_unavailable") && r.body.contains("not generated yet"))
}

@Test func summaryServesExactlyDateAndText() async throws {
    let r = try await get(await seeded())
    #expect(r.status == .ok)
    #expect(!r.body.contains("null"))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any])
    #expect(Set(json.keys) == ["date", "text"])
    #expect(json["text"] as? String == "Otto has Pajama Day at school.")
    let date = try #require(json["date"] as? String)
    #expect(date == SummaryDay.string(for: Date(), timeZone: .current))
}

@Test func healthzOmitsSummaryWithoutTheFeedAndIncludesItWith() async throws {
    let without = try await get(nil, "/healthz")
    #expect(!without.body.contains("\"summary\""))
    let with = try await get(await seeded(), "/healthz")
    let health = try JSONDecoder().decode(Health.self, from: Data(with.body.utf8))
    #expect(health.feeds.summary?.status == .ok)
    let missing = try await get(SummaryFeed(calendar: nil, chores: nil, people: []), "/healthz")
    let bad = try JSONDecoder().decode(Health.self, from: Data(missing.body.utf8))
    #expect(bad.feeds.summary?.status == .error && bad.feeds.summary?.detail == "not configured")
    #expect(bad.status == .degraded)
    #expect(!missing.body.contains("null"))
}

@Test func contractVersionIs0150() {
    #expect(contractVersion == "0.15.0")
}
