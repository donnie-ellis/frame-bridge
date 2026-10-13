import Foundation
@testable import FrameBridgeCore
import Testing

enum WeatherFixture {
    static func data() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "open-meteo-forecast", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    static func forecast() throws -> OpenMeteoForecast {
        try JSONDecoder().decode(OpenMeteoForecast.self, from: data())
    }
}
