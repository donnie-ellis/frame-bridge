import HTTPTypes
import Hummingbird

/// Refuses non-GET requests whose Origin isn't the page's own origin (plain HTTP, same Host).
struct OriginCheckMiddleware: RouterMiddleware {
    static func isAllowed(method: HTTPRequest.Method, origin: String?, host: String?) -> Bool {
        if method == .get { return true }
        guard let origin else { return true }
        guard let host else { return false }
        return origin.lowercased() == ("http://" + host).lowercased()
    }

    func handle(
        _ request: Request,
        context: FrameRequestContext,
        next: (Request, FrameRequestContext) async throws -> Response
    ) async throws -> Response {
        guard Self.isAllowed(method: request.method, origin: request.headers[.origin], host: request.head.authority) else {
            // Method only: never the Origin value, Cookie or path.
            context.logger.info("cross-origin write refused", metadata: ["method": .string(request.method.rawValue)])
            return try APIError.forbidden.response()
        }
        return try await next(request, context)
    }
}
