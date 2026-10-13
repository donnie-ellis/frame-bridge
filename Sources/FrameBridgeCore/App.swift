import Hummingbird
import Logging

/// The `info.version` of `frame-bridge.openapi.yaml` this build implements.
public let contractVersion = "0.3.0"

public func buildRouter(config: Config) -> Router<FrameRequestContext> {
    let router = Router(context: FrameRequestContext.self)
    // Before every route, so none can skip the token check.
    router.add(middleware: FrameTokenMiddleware(store: TokenStore(config: config)))
    // After the token check, so authenticated logs carry the frame name.
    router.add(middleware: LogRequestsMiddleware(.info))
    // After the token check: files need the cookie too.
    router.add(middleware: DashboardFilesMiddleware(config: config))
    router.get("healthz") { _, _ in
        Health(feeds: .init(
            calendar: .notImplemented(staleAfterSeconds: 900),
            shopping: .notImplemented(staleAfterSeconds: 300),
            lights: .notImplemented(staleAfterSeconds: 120),
            weather: .notImplemented(staleAfterSeconds: 7200),
            photos: .notImplemented(staleAfterSeconds: 172800)
        ))
    }
    return router
}

/// Listens on all interfaces: the frames reach it on the LAN at port 8787. The frame_token check
/// is the only gate, so never expose this port beyond the LAN.
public func buildApplication(config: Config) -> some ApplicationProtocol {
    let logger = Logger(label: "frame-bridge")
    switch DashboardFilesMiddleware.directoryStatus(config.dashboardDir) {
    case .ready: break
    case .missing: logger.warning("dashboardDir is missing, files will return 404", metadata: ["path": .string(config.dashboardDir)])
    case .empty: logger.warning("dashboardDir is empty, files will return 404", metadata: ["path": .string(config.dashboardDir)])
    }
    return Application(
        router: buildRouter(config: config),
        configuration: .init(address: .hostname("0.0.0.0", port: 8787), serverName: "frame-bridge")
    )
}
