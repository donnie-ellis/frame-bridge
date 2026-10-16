import Foundation
import Logging

/// Log metadata and health text for Hue failures. Built from the error code and HTTP status
/// only: never a URL, host, key or localizedDescription.
enum HueFailure {
    private static let names: [URLError.Code: (name: String, phrase: String)] = [
        .networkConnectionLost: ("networkConnectionLost", "connection lost"),
        .cannotConnectToHost: ("cannotConnectToHost", "connection refused"),
        .timedOut: ("timedOut", "timed out"),
        .cannotFindHost: ("cannotFindHost", "host not found"),
        .dnsLookupFailed: ("dnsLookupFailed", "host not found"),
        .notConnectedToInternet: ("notConnectedToInternet", "no network"),
        .secureConnectionFailed: ("secureConnectionFailed", "TLS failed"),
        .cancelled: ("cancelled", "cancelled"),
        .badServerResponse: ("badServerResponse", "bad response"),
    ]

    static func logMetadata(for error: any Error) -> Logger.Metadata {
        switch error as? HueClientError {
        case .network(let code):
            ["reason": .string(names[code]?.name ?? "urlError"), "code": .string(String(code.rawValue))]
        case .status(let n): ["reason": "status", "code": .string(String(n))]
        case .unauthorized: ["reason": "unauthorized"]
        case .pinMismatch: ["reason": "pinMismatch"]
        case .badResponse: ["reason": "badResponse"]
        case .notFound: ["reason": "notFound"]
        default: ["reason": "unreachable"]
        }
    }

    static func streamDetail(for error: any Error) -> String {
        switch error as? HueClientError {
        case .network(let code): "Hue event stream: \(names[code]?.phrase ?? "network error") (\(code.rawValue))"
        case .status(let n): "Hue event stream: HTTP \(n)"
        case .badResponse: "Hue event stream: bad response"
        case .pinMismatch: "Hue Bridge certificate doesn't match the pin: run hue-pair"
        case .unauthorized: "Hue application key rejected: run hue-pair"
        default: "Hue event stream: Hue Bridge not reachable"
        }
    }
}
