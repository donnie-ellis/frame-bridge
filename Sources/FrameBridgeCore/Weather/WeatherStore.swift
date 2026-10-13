import Foundation
import Logging

/// Last good forecast plus the state of the latest fetch.
public actor WeatherStore {
    static let staleAfterSeconds = 7200

    private let fetcher: any ForecastFetching
    private let timeZone: TimeZone
    private let logger: Logger
    private var forecast: Weather?
    private var lastSuccess: Date?
    private var lastError: String?
    private var loggedCodes = Set<Int>()

    init(fetcher: any ForecastFetching, timeZone: TimeZone = .current, logger: Logger = Logger(label: "frame-bridge.weather")) {
        self.fetcher = fetcher
        self.timeZone = timeZone
        self.logger = logger
    }

    public init(config: WeatherConfig, logger: Logger) {
        self.init(fetcher: OpenMeteoClient(config: config), logger: logger)
    }

    /// On failure keeps serving the last good forecast.
    public func refresh() async {
        do {
            let data = try await fetcher.fetchForecast()
            let parsed = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
            let (weather, unknown) = try WeatherMapping.map(parsed, timeZone: timeZone)
            for code in unknown.subtracting(loggedCodes).sorted() {
                loggedCodes.insert(code)
                logger.warning("unknown Open-Meteo weather code, shown as cloud", metadata: ["code": .stringConvertible(code)])
            }
            forecast = weather
            lastSuccess = Date()
            lastError = nil
        } catch {
            let detail = Self.describe(error)
            lastError = detail
            logger.warning("weather refresh failed", metadata: ["reason": .string(detail)])
        }
    }

    /// Short and free of URLs and coordinates: it goes to /healthz and the log.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let e as ForecastFetchError: e.description
        case is DecodingError: "unexpected response shape"
        case let e as WeatherMappingError:
            switch e {
            case .tooFewHours(let n): "forecast has \(n) hours, need 48"
            case .missingValue: "forecast is missing a value"
            }
        default: "fetch failed"
        }
    }

    func current() throws -> Weather {
        guard let forecast else { throw APIError.sourceUnavailable("no forecast yet") }
        return forecast
    }

    func health() -> FeedHealth {
        let updated = lastSuccess.map { WireDate.string(from: $0, timeZone: timeZone) }
        if let lastError {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: lastError, updatedAt: updated)
        }
        guard let updated else {
            return FeedHealth(status: .error, staleAfterSeconds: Self.staleAfterSeconds, detail: "no forecast yet")
        }
        return FeedHealth(status: .ok, staleAfterSeconds: Self.staleAfterSeconds, updatedAt: updated)
    }
}
