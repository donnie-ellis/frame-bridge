import Foundation
import Testing

@testable import FrameBridgeCore

@Test func tokenStoreMatchesAndRejects() {
    let token = UUID().uuidString
    let store = TokenStore(hashes: ["kitchen": TestAuth.hex(sha256: token)])
    #expect(store.frameName(forToken: token) == "kitchen")
    #expect(store.frameName(forToken: UUID().uuidString) == nil)
    #expect(store.frameName(forToken: "") == nil)
}

@Test func tokenStoreResolvesEachFrame() {
    let a = UUID().uuidString, b = UUID().uuidString
    let hashes = ["kitchen": TestAuth.hex(sha256: a), "hallway": TestAuth.hex(sha256: b)]
    let store = TokenStore(hashes: hashes)
    #expect(store.frameName(forToken: a) == "kitchen")
    #expect(store.frameName(forToken: b) == "hallway")
    let revoked = TokenStore(hashes: ["hallway": hashes["hallway"]!])
    #expect(revoked.frameName(forToken: a) == nil)
    #expect(revoked.frameName(forToken: b) == "hallway")
}
