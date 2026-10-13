import Foundation
import HTTPTypes
import Hummingbird

/// The spec's `Error` shape: `{ "error": code, "detail"?: ... }`.
public struct APIError: HTTPResponseError, Codable, Sendable {
    public let error: String
    public let detail: String?
    public let status: HTTPResponse.Status

    private enum CodingKeys: String, CodingKey { case error, detail }

    public init(error: String, detail: String? = nil, status: HTTPResponse.Status) {
        self.error = error
        self.detail = detail
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try c.decode(String.self, forKey: .error)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        status = .badRequest
    }

    public static let unauthorized = APIError(error: "unauthorized", status: .unauthorized)
    public static let notFound = APIError(error: "not_found", status: .notFound)
    public static func badRequest(_ detail: String) -> APIError {
        APIError(error: "bad_request", detail: detail, status: .badRequest)
    }
    public static func sourceUnavailable(_ detail: String) -> APIError {
        APIError(error: "source_unavailable", detail: detail, status: .serviceUnavailable)
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        try response()
    }

    public func response() throws -> Response {
        let data = try JSONEncoder().encode(self)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}
