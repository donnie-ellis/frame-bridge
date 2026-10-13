import Hummingbird

/// The `info.version` of `frame-bridge.openapi.yaml` this build implements.
public let contractVersion = "0.1.0"

public func buildRouter() -> Router<BasicRequestContext> {
    let router = Router()
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
/// (not built yet) will be the only gate, so never expose this port beyond the LAN.
public func buildApplication() -> some ApplicationProtocol {
    Application(
        router: buildRouter(),
        configuration: .init(address: .hostname("0.0.0.0", port: 8787), serverName: "frame-bridge")
    )
}
