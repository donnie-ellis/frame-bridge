import Foundation

/// Sends a request to the bridge. The path is relative to `https://<bridge>/clip/v2/`.
protocol HueTransport: Sendable {
    func send(method: String, path: String, body: Data?) async throws -> (status: Int, data: Data)
}

/// No key, address or names in these.
enum HueClientError: Error, Equatable {
    case notFound
    case unauthorized
    case status(Int)
    case unreachable
    case badResponse
}

struct HueClient: Sendable {
    let transport: any HueTransport

    /// Six requests in parallel: Hue allows about ten a second.
    func resources() async throws -> HueResources {
        async let lights: [HueLight] = list("resource/light")
        async let devices: [HueDevice] = list("resource/device")
        async let rooms: [HueGroup] = list("resource/room")
        async let zones: [HueGroup] = list("resource/zone")
        async let groupedLights: [HueGroupedLight] = list("resource/grouped_light")
        async let scenes: [HueScene] = list("resource/scene")
        return try await HueResources(lights: lights, devices: devices, rooms: rooms, zones: zones, groupedLights: groupedLights, scenes: scenes)
    }

    func light(id: String) async throws -> HueLight {
        guard let first = try await list("resource/light/\(id)", as: HueLight.self).first else { throw HueClientError.notFound }
        return first
    }

    func putLight(id: String, body: Data) async throws {
        _ = try await request("PUT", "resource/light/\(id)", body: body)
    }

    func groupedLight(id: String) async throws -> HueGroupedLight {
        guard let first = try await list("resource/grouped_light/\(id)", as: HueGroupedLight.self).first else { throw HueClientError.notFound }
        return first
    }

    func putGroupedLight(id: String, body: Data) async throws {
        _ = try await request("PUT", "resource/grouped_light/\(id)", body: body)
    }

    func putScene(id: String, body: Data) async throws {
        _ = try await request("PUT", "resource/scene/\(id)", body: body)
    }

    private func list<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> [T] {
        let data = try await request("GET", path, body: nil)
        do {
            return try JSONDecoder().decode(HueEnvelope<T>.self, from: data).data
        } catch {
            throw HueClientError.badResponse
        }
    }

    private func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let result: (status: Int, data: Data)
        do {
            result = try await transport.send(method: method, path: path, body: body)
        } catch let error as HueClientError {
            throw error
        } catch {
            throw HueClientError.unreachable
        }
        switch result.status {
        case 200..<300: return result.data
        case 404: throw HueClientError.notFound
        case 401, 403: throw HueClientError.unauthorized
        default: throw HueClientError.status(result.status)
        }
    }
}
