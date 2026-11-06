import Foundation
import Testing
import struct os.OSAllocatedUnfairLock

@testable import FrameBridgeCore

private let accountId = "0123456789abcdef0123456789abcdef"
private let token = "TOKEN-SENTINEL-" + UUID().uuidString
private let model = "@cf/example/model-8b"
private let prompt = SummaryPrompt(system: "SYSTEM TEXT", user: "USER TEXT")

private final class FakeTransport: WorkersAITransport, Sendable {
    private let seen = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
    let result: Result<(status: Int, data: Data), any Error>
    var request: URLRequest? { seen.withLock { $0 } }
    init(_ result: Result<(status: Int, data: Data), any Error>) { self.result = result }
    func post(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        seen.withLock { $0 = request }
        return try result.get()
    }
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/workers-ai"))
    return try Data(contentsOf: url)
}

private func client(_ transport: FakeTransport) -> WorkersAIClient {
    WorkersAIClient(accountId: accountId, token: token, model: model, transport: transport)
}

private func reply(_ text: String) -> Data {
    let body: [String: Any] = ["result": ["response": text], "success": true, "errors": [], "messages": []]
    return try! JSONSerialization.data(withJSONObject: body)
}

@Test func requestGoesToCloudflareWithOnlyThePromptMessages() async throws {
    let transport = FakeTransport(.success((200, try fixture("run-response"))))
    let text = try await client(transport).generate(prompt)
    #expect(text == "Otto has Pajama Day at school, and Maya and Jordan are off to the dentist at noon. Alex is on bins tonight.")
    let request = try #require(transport.request)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.scheme == "https")
    #expect(request.url?.host == "api.cloudflare.com")
    #expect(request.url?.path == "/client/v4/accounts/\(accountId)/ai/run/\(model)")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(Set(body.keys) == ["messages", "max_tokens"])
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages == [["role": "system", "content": "SYSTEM TEXT"], ["role": "user", "content": "USER TEXT"]])
}

@Test func replyIsTrimmedAndChecked() throws {
    #expect(try WorkersAIClient.replyText(from: reply("  Hello there.\n")) == "Hello there.")
    #expect(throws: WorkersAIError.emptyReply) { try WorkersAIClient.replyText(from: reply(" \n\t ")) }
    #expect(throws: WorkersAIError.emptyReply) { try WorkersAIClient.replyText(from: reply("")) }
    #expect(throws: WorkersAIError.tooLong) { try WorkersAIClient.replyText(from: reply(String(repeating: "a", count: 401))) }
    #expect(try WorkersAIClient.replyText(from: reply(String(repeating: "a", count: 400))).unicodeScalars.count == 400)
    #expect(try WorkersAIClient.replyText(from: reply("  " + String(repeating: "a", count: 400) + "  ")).unicodeScalars.count == 400)
}

@Test func malformedAndFailedRepliesAreRejected() throws {
    #expect(throws: WorkersAIError.badResponse) { try WorkersAIClient.replyText(from: try fixture("run-error")) }
    #expect(throws: WorkersAIError.badResponse) { try WorkersAIClient.replyText(from: Data("nope".utf8)) }
    #expect(throws: WorkersAIError.badResponse) { try WorkersAIClient.replyText(from: Data(#"{"result":{"response":{"a":1}},"success":true}"#.utf8)) }
    #expect(throws: WorkersAIError.badResponse) { try WorkersAIClient.replyText(from: Data(#"{"result":{"response":"x"},"success":false}"#.utf8)) }
}

@Test func nonSuccessStatusAndNetworkFailuresThrow() async throws {
    await #expect(throws: WorkersAIError.http(401)) { try await client(FakeTransport(.success((401, try fixture("run-error"))))).generate(prompt) }
    await #expect(throws: WorkersAIError.http(500)) { try await client(FakeTransport(.success((500, Data())))).generate(prompt) }
    await #expect(throws: WorkersAIError.network(URLError.timedOut.rawValue)) { try await client(FakeTransport(.failure(URLError(.timedOut)))).generate(prompt) }
}

@Test func errorsNeverCarryTheAccountIdOrToken() async throws {
    let failures: [Result<(status: Int, data: Data), any Error>] = [.success((403, Data())), .failure(URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://api.cloudflare.com/\(accountId)"])), .success((200, Data("x".utf8)))]
    for result in failures {
        do {
            _ = try await client(FakeTransport(result)).generate(prompt)
            Issue.record("expected a failure")
        } catch {
            for text in [String(describing: error), "\(error)", error.localizedDescription] {
                #expect(!text.contains(accountId) && !text.contains(token))
            }
        }
    }
}
