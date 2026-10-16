import HTTPTypes
import Hummingbird

/// Sets the spec's security headers on every response, errors included.
struct SecurityHeadersMiddleware: RouterMiddleware {
    func handle(
        _ request: Request,
        context: FrameRequestContext,
        next: (Request, FrameRequestContext) async throws -> Response
    ) async throws -> Response {
        var response: Response
        do {
            response = try await next(request, context)
        } catch let error as HTTPResponseError {
            // Thrown errors only become responses after the router, so render them here.
            response = try error.response(from: request, context: context)
        }
        response.headers[.xContentTypeOptions] = "nosniff"
        response.headers[.referrerPolicy] = "no-referrer"
        response.headers[.xFrameOptions] = "DENY"
        response.headers[.contentSecurityPolicy] = "frame-ancestors 'none'; object-src 'none'; base-uri 'none'"
        return response
    }
}

private extension HTTPField.Name {
    static let xContentTypeOptions = HTTPField.Name("X-Content-Type-Options")!
    static let referrerPolicy = HTTPField.Name("Referrer-Policy")!
    static let xFrameOptions = HTTPField.Name("X-Frame-Options")!
    static let contentSecurityPolicy = HTTPField.Name("Content-Security-Policy")!
}
