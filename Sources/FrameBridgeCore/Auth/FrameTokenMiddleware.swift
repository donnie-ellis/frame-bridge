import Hummingbird

/// Gates every route on the `frame_token` cookie. No header or query fallback.
struct FrameTokenMiddleware: RouterMiddleware {
    let store: TokenStore

    func handle(
        _ request: Request,
        context: FrameRequestContext,
        next: (Request, FrameRequestContext) async throws -> Response
    ) async throws -> Response {
        let token = request.cookies["frame_token"]?.value ?? ""
        guard let name = store.frameName(forToken: token) else {
            // Remote address only: never the token, its hash or the Cookie header.
            context.logger.info(
                "unauthorized",
                metadata: ["remote": .string(context.remoteAddress?.ipAddress ?? "unknown")]
            )
            return try APIError.unauthorized.response()
        }
        var context = context
        context.logger[metadataKey: "frame"] = .string(name)
        return try await next(request, context)
    }
}
