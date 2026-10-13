import Foundation

/// The parts of Open-Meteo's response we use. Source-side names, never on our wire.
struct OpenMeteoForecast: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let temperature: [Double?]
        let precipitationProbability: [Int?]
        let weatherCode: [Int?]
        let isDay: [Int?]

        private enum CodingKeys: String, CodingKey {
            case time
            case temperature = "temperature_2m"
            case precipitationProbability = "precipitation_probability"
            case weatherCode = "weather_code"
            case isDay = "is_day"
        }
    }

    struct Daily: Decodable {
        let time: [String]
        let max: [Double?]
        let min: [Double?]

        private enum CodingKeys: String, CodingKey {
            case time
            case max = "temperature_2m_max"
            case min = "temperature_2m_min"
        }
    }

    let hourly: Hourly
    let daily: Daily
}

enum WeatherMappingError: Error, Equatable {
    case tooFewHours(Int)
    case missingValue
}

enum WeatherMapping {
    static let hours = 48

    /// Open-Meteo weather code -> icon name, per the spec's `WeatherCondition`. nil: not in the table.
    static func condition(code: Int, isDay: Bool) -> WeatherCondition? {
        switch code {
        case 0, 1: isDay ? .sun : .moon
        case 2: .partly
        case 3, 45, 48: .cloud
        case 51...67, 80...82: .rain
        case 71...77, 85...86: .snow
        case 95...99: .storm
        default: nil
        }
    }

    /// Rounds without producing -0. No unit conversion: the request asks Open-Meteo for the unit.
    private static func round(_ v: Double) -> Int { Int(v.rounded()) }

    /// Unknown codes map to `cloud` and are returned so the caller can log them.
    static func map(_ f: OpenMeteoForecast, timeZone: TimeZone) throws -> (weather: Weather, unknownCodes: Set<Int>) {
        let h = f.hourly
        let n = min(h.temperature.count, h.weatherCode.count, h.isDay.count, h.precipitationProbability.count)
        guard n >= hours else { throw WeatherMappingError.tooFewHours(n) }
        guard let day = f.daily.time.first, let hi = f.daily.max.first ?? nil, let lo = f.daily.min.first ?? nil
        else { throw WeatherMappingError.missingValue }

        var t: [Int] = [], c: [WeatherCondition] = [], p: [Int] = []
        var unknown = Set<Int>()
        for i in 0..<hours {
            guard let temp = h.temperature[i], let code = h.weatherCode[i], let isDay = h.isDay[i]
            else { throw WeatherMappingError.missingValue }
            t.append(round(temp))
            if let cond = condition(code: code, isDay: isDay == 1) {
                c.append(cond)
            } else {
                c.append(.cloud)
                unknown.insert(code)
            }
            p.append(min(max(h.precipitationProbability[i] ?? 0, 0), 100))
        }

        // The forecast's own first day, at local midnight in the Mac's zone.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let midnight = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { throw WeatherMappingError.missingValue }

        let weather = Weather(start: WireDate.string(from: midnight, timeZone: timeZone), hi: round(hi), lo: round(lo), t: t, c: c, p: p)
        return (weather, unknown)
    }
}
