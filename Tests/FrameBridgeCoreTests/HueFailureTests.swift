import Foundation
import Testing

@testable import FrameBridgeCore

@Test(arguments: [
    (URLError.Code.networkConnectionLost, "networkConnectionLost", "-1005", "connection lost"),
    (.cannotConnectToHost, "cannotConnectToHost", "-1004", "connection refused"),
    (.timedOut, "timedOut", "-1001", "timed out"),
    (.cannotFindHost, "cannotFindHost", "-1003", "host not found"),
    (.dnsLookupFailed, "dnsLookupFailed", "-1006", "host not found"),
    (.notConnectedToInternet, "notConnectedToInternet", "-1009", "no network"),
    (.secureConnectionFailed, "secureConnectionFailed", "-1200", "TLS failed"),
    (.cancelled, "cancelled", "-999", "cancelled"),
    (.badServerResponse, "badServerResponse", "-1011", "bad response"),
    (.cannotParseResponse, "urlError", "-1017", "network error"),
])
func networkErrorsMapToReasonCodeAndDetail(code: URLError.Code, reason: String, raw: String, phrase: String) {
    let error = HueClientError.network(code)
    #expect(HueFailure.logMetadata(for: error) == ["reason": .string(reason), "code": .string(raw)])
    #expect(HueFailure.streamDetail(for: error) == "Hue event stream: \(phrase) (\(raw))")
}

@Test func httpStatusKeepsItsCode() {
    #expect(HueFailure.logMetadata(for: HueClientError.status(503)) == ["reason": "status", "code": "503"])
    #expect(HueFailure.streamDetail(for: HueClientError.status(503)) == "Hue event stream: HTTP 503")
}

@Test func otherFailuresHaveAReasonAndNoCode() {
    #expect(HueFailure.logMetadata(for: HueClientError.unauthorized) == ["reason": "unauthorized"])
    #expect(HueFailure.logMetadata(for: HueClientError.pinMismatch) == ["reason": "pinMismatch"])
    #expect(HueFailure.logMetadata(for: HueClientError.badResponse) == ["reason": "badResponse"])
    #expect(HueFailure.logMetadata(for: HueClientError.unreachable) == ["reason": "unreachable"])
    #expect(HueFailure.streamDetail(for: HueClientError.badResponse) == "Hue event stream: bad response")
    #expect(HueFailure.streamDetail(for: HueClientError.unreachable) == "Hue event stream: Hue Bridge not reachable")
}

@Test func aRejectedPinIsAPinMismatch() {
    let rejected = HueClientError(urlError: .cancelled, pinRejected: true)
    #expect(rejected == .pinMismatch)
    #expect(HueFailure.streamDetail(for: rejected) == "Hue Bridge certificate doesn't match the pin: run hue-pair")
    #expect(HueClientError(urlError: .cancelled, pinRejected: false) == .network(.cancelled))
}

@Test func theFailingURLNeverReachesTheOutput() {
    let urlError = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://bridge.invalid/eventstream/clip/v2")!])
    let error = HueClientError(urlError: urlError.code, pinRejected: false)
    let text = "\(HueFailure.logMetadata(for: error)) \(HueFailure.streamDetail(for: error))"
    #expect(!text.contains("bridge.invalid"))
}
