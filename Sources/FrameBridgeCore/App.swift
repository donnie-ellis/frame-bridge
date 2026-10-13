import Hummingbird

/// The `info.version` of `frame-bridge.openapi.yaml` this build implements.
public let contractVersion = "0.1.0"

public func buildRouter(config: Config) -> Router<FrameRequestContext> {
    let router = Router(context: FrameRequestContext.self)
    // Before every route, so none can skip the token check.
    router.add(middleware: FrameTokenMiddleware(store: TokenStore(config: config)))
    // After the token check, so authenticated logs carry the frame name.
    router.add(middleware: LogRequestsMiddleware(.info))
    router.get("healthz") { _, _ in
        Health(feeds: .init(
            calendar: .notImplemented(staleAfterSeconds: 900),
            shopping: .notImplemented(staleAfterSeconds: 300),
            lights: .notImplemented(staleAfterSeconds: 120)
        ))
    }
    return router
}

/// Listens on all interfaces: the frames reach it on the LAN at port 8787. The frame_token check
/// is the only gate, so never expose this port beyond the LAN.
public func buildApplication(config: Config) -> some ApplicationProtocol {
    Application(
        router: buildRouter(config: config),
        configuration: .init(address: .hostname("0.0.0.0", port: 8787), serverName: "frame-bridge")
    )
}
