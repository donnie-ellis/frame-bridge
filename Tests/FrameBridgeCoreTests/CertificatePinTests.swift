import Foundation
import Testing

@testable import FrameBridgeCore

@Test func sha256HexOfKnownBytes() {
    #expect(CertificatePin.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func pinMatchesSameBytesAndIgnoresCase() {
    let der = Data("cert".utf8)
    let pin = CertificatePin.sha256Hex(der)
    #expect(CertificatePin.matches(der: der, pinHex: pin))
    #expect(CertificatePin.matches(der: der, pinHex: pin.uppercased()))
}

@Test func pinRejectsChangedBytesAndEmptyPin() {
    let pin = CertificatePin.sha256Hex(Data("cert".utf8))
    #expect(!CertificatePin.matches(der: Data("cerT".utf8), pinHex: pin))
    #expect(!CertificatePin.matches(der: Data("cert".utf8), pinHex: ""))
}

/// `bytes(for:)` (the event stream) only asks the task-level challenge method, so both must exist.
@Test func thePinIsCheckedForTheEventStreamToo() {
    let delegate = PinnedCertificateDelegate(pin: "00")
    #expect(delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))))
    #expect(delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))))
}
