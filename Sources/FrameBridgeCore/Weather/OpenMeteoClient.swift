import Foundation

protocol ForecastFetching: Sendable {
    func fetchForecast() async throws -> Data
}

/// Errors carry a status or a URLError code only: the URL holds the home coordinates.
enum ForecastFetchError: Error, CustomStringConvertible {
    case status(Int)
    case network(Int)
    case badResponse

    var description: String {
        switch self {
        case .status(let s): "Open-Meteo returned HTTP \(s)"
        case .network(let code): "network error \(code)"
        case .badResponse: "unexpected response"
        }
    }
}

struct OpenMeteoClient: ForecastFetching {
    let latitude: Double
    let longitude: Double
    let unit: TemperatureUnit

    init(config: WeatherConfig) {
        latitude = config.latitude
        longitude = config.longitude
        unit = config.unit
    }

    private func url() -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var items = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        if unit == .fahrenheit { items.append(URLQueryItem(name: "temperature_unit", value: "fahrenheit")) }
        c?.queryItems = items
        return c?.url
    }

    func fetchForecast() async throws -> Data {
        guard let url = url() else { throw ForecastFetchError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ForecastFetchError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw ForecastFetchError.status(http.statusCode) }
            return data
        } catch let error as URLError {
            throw ForecastFetchError.network(error.code.rawValue)
        }
    }
}
