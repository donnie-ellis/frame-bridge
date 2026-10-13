import Foundation
import HTTPTypes
import Hummingbird
import Logging
import ServiceLifecycle

/// The `info.version` of `frame-bridge.openapi.yaml` this build implements.
public let contractVersion = "0.3.0"

public func buildRouter(config: Config, weather: WeatherStore? = nil, calendar: CalendarFeed? = nil, events: EventHub = EventHub()) -> Router<FrameRequestContext> {
    let router = Router(context: FrameRequestContext.self)
    // Before every route, so none can skip the token check.
    router.add(middleware: FrameTokenMiddleware(store: TokenStore(config: config)))
    // After the token check, so authenticated logs carry the frame name.
    router.add(middleware: LogRequestsMiddleware(.info))
    // After the token check: files need the cookie too.
    router.add(middleware: DashboardFilesMiddleware(config: config))
    events.addRoutes(to: router)
    router.get("api/weather") { _, _ -> Weather in
        guard let weather else { throw APIError.sourceUnavailable("not configured") }
        return try await weather.current()
    }
    router.get("api/calendar") { request, _ -> Response in
        guard let calendar else { throw APIError.sourceUnavailable("not configured") }
        let range = try CalendarQuery.parse(from: request.uri.queryParameters["from"].map(String.init), to: request.uri.queryParameters["to"].map(String.init), timeZone: .current)
        let events = try await calendar.events(from: range.from, to: range.to)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: try JSONEncoder().encode(events))))
    }
    router.get("healthz") { _, _ in
        let calendarHealth: FeedHealth
        if let calendar {
            calendarHealth = await calendar.health()
        } else {
            calendarHealth = .notConfigured(staleAfterSeconds: CalendarFeed.staleAfterSeconds)
        }
        let weatherHealth: FeedHealth
        if let weather {
            weatherHealth = await weather.health()
        } else {
            weatherHealth = .notConfigured(staleAfterSeconds: WeatherStore.staleAfterSeconds)
        }
        return Health(feeds: .init(
            calendar: calendarHealth,
            shopping: .notImplemented(staleAfterSeconds: 300),
            lights: .notImplemented(staleAfterSeconds: 120),
            weather: weatherHealth,
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
    let events = EventHub()
    var weather: WeatherStore?
    if let weatherConfig = config.weather {
        weather = WeatherStore(config: weatherConfig, logger: logger, events: events)
    } else {
        logger.info("weather not configured")
    }
    var calendar: CalendarFeed?
    var calendarService: EventStoreService?
    if let calendarConfig = config.calendar {
        let store = SharedEventStore()
        let debouncer = EventStoreDebouncer()
        let feed = CalendarFeed(config: calendarConfig, provider: EventKitCalendarSource(store: store))
        calendar = feed
        calendarService = EventStoreService(store: store, debouncer: debouncer, feed: feed) { await events.calendarChanged() }
    } else {
        logger.info("calendar not configured")
    }
    var app = Application(
        router: buildRouter(config: config, weather: weather, calendar: calendar, events: events),
        configuration: .init(address: .hostname("0.0.0.0", port: 8787), serverName: "frame-bridge")
    )
    app.addServices(EventPingService(hub: events))
    if let weather { app.addServices(WeatherRefreshService(store: weather)) }
    if let calendarService { app.addServices(calendarService) }
    return app
}
