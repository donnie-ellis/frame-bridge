import Foundation

protocol SummaryGenerating: Sendable {
    /// The reply text, trimmed and checked. Throws when the model can't be reached or the reply is rejected.
    func generate(_ prompt: SummaryPrompt) async throws -> String
}

protocol WorkersAITransport: Sendable {
    func post(_ request: URLRequest) async throws -> (status: Int, data: Data)
}

/// Holds only a status, an error code or a reason: never the URL (it has the account id), the
/// token, the prompt or the reply.
enum WorkersAIError: Error, Equatable {
    case http(Int)
    case network(Int)
    case badResponse
    case emptyReply
    case tooLong
}

struct WorkersAIClient: SummaryGenerating {
    static let maxReplyScalars = 400
    static let maxTokens = 200

    let accountId: String
    let token: String
    let model: String
    let transport: any WorkersAITransport

    func generate(_ prompt: SummaryPrompt) async throws -> String {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/ai/run/\(model)") else {
            throw WorkersAIError.badResponse
        }
        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable { let messages: [Message]; let max_tokens: Int }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(messages: [Message(role: "system", content: prompt.system), Message(role: "user", content: prompt.user)], max_tokens: Self.maxTokens))
        let response: (status: Int, data: Data)
        do {
            response = try await transport.post(request)
        } catch let error as URLError {
            throw WorkersAIError.network(error.code.rawValue)
        }
        guard (200..<300).contains(response.status) else { throw WorkersAIError.http(response.status) }
        return try Self.replyText(from: response.data)
    }

    /// `{ "result": { "response": "..." }, "success": true, ... }` -> the trimmed text, 1 to 400 characters.
    static func replyText(from data: Data) throws -> String {
        struct Reply: Decodable {
            struct Result: Decodable { let response: String }
            let success: Bool?
            let result: Result?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.success != false, let result = reply.result else {
            throw WorkersAIError.badResponse
        }
        let text = result.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw WorkersAIError.emptyReply }
        if text.unicodeScalars.count > maxReplyScalars { throw WorkersAIError.tooLong }
        return text
    }
}

/// No cookies, credentials store, cache or redirects.
final class URLSessionWorkersAITransport: WorkersAITransport, Sendable {
    static let timeout: TimeInterval = 15

    private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        session = URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
    }

    func post(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkersAIError.badResponse }
        return (http.statusCode, data)
    }
}
