import Foundation
import Testing

@testable import FrameBridgeCore

@Test(arguments: [(#"{"done":true}"#, true), (#"{"done":false}"#, false)])
func shoppingPatchAcceptsValid(json: String, expected: Bool) throws {
    #expect(try ShoppingItemPatch.parse(Data(json.utf8)).done == expected)
}

@Test(arguments: [
    "", "[]", #""x""#, "{}", "nope", #"{"done":1}"#, #"{"done":"true"}"#, #"{"done":null}"#, #"{"done":true,"qty":2}"#,
])
func shoppingPatchRejectsInvalid(json: String) {
    #expect(throws: APIError.self) { try ShoppingItemPatch.parse(Data(json.utf8)) }
}
