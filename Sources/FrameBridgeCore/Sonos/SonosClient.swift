import Foundation

enum SonosError: Error, Equatable {
    case unreachable
    case status(Int)
    case roomNotFound
    case badResponse
}

/// Plain HTTP to a speaker on port 1400. Implementations must keep hosts and paths out of errors.
protocol SonosTransport: Sendable {
    /// `action` is the SOAPACTION value without quotes: `<serviceType>#<Action>`.
    func soap(host: String, path: String, action: String, body: Data) async throws -> Data
    func get(host: String, path: String) async throws -> (status: Int, data: Data)
}

/// Read only. These four calls are everything frame-bridge ever sends to a speaker: no play,
/// pause, volume or any other write action.
struct SonosClient: Sendable {
    static let topologyService = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
    static let transportService = "urn:schemas-upnp-org:service:AVTransport:1"
    static let topologyPath = "/ZoneGroupTopology/Control"
    static let transportPath = "/MediaRenderer/AVTransport/Control"
    static let artPrefix = "/getaa"

    let transport: any SonosTransport

    func zoneGroupState(host: String) async throws -> Data {
        try await transport.soap(host: host, path: Self.topologyPath, action: "\(Self.topologyService)#GetZoneGroupState", body: Self.envelope(service: Self.topologyService, action: "GetZoneGroupState", arguments: ""))
    }

    func transportInfo(host: String) async throws -> Data {
        try await transport.soap(host: host, path: Self.transportPath, action: "\(Self.transportService)#GetTransportInfo", body: Self.envelope(service: Self.transportService, action: "GetTransportInfo", arguments: "<InstanceID>0</InstanceID>"))
    }

    func positionInfo(host: String) async throws -> Data {
        try await transport.soap(host: host, path: Self.transportPath, action: "\(Self.transportService)#GetPositionInfo", body: Self.envelope(service: Self.transportService, action: "GetPositionInfo", arguments: "<InstanceID>0</InstanceID>"))
    }

    /// Only the speaker's own `/getaa` art, never an absolute URL.
    func art(host: String, path: String) async throws -> (status: Int, data: Data) {
        guard path.hasPrefix(Self.artPrefix) else { throw SonosError.badResponse }
        return try await transport.get(host: host, path: path)
    }

    static func envelope(service: String, action: String, arguments: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\(arguments)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
    }
}

struct URLSessionSonosTransport: SonosTransport {
    static let maxArtBytes = 5_000_000
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
    }

    private func url(host: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 1400
        // `path` may carry a query (`/getaa?...`), which URLComponents.path would escape.
        guard let base = components.url, let url = URL(string: base.absoluteString + path) else { throw SonosError.unreachable }
        return url
    }

    func soap(host: String, path: String, action: String, body: Data) async throws -> Data {
        var request = URLRequest(url: try url(host: host, path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("\"\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        let (status, data) = try await send(request)
        guard (200..<300).contains(status) else { throw SonosError.status(status) }
        return data
    }

    func get(host: String, path: String) async throws -> (status: Int, data: Data) {
        try await send(URLRequest(url: try url(host: host, path: path)))
    }

    private func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SonosError.badResponse }
            guard data.count <= Self.maxArtBytes else { throw SonosError.badResponse }
            return (http.statusCode, data)
        } catch is URLError {
            throw SonosError.unreachable
        }
    }
}
