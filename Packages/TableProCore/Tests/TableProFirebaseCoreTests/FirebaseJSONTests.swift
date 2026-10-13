import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("FirebaseJSON")
struct FirebaseJSONTests {
    @Test("Integers and doubles stay apart")
    func numberKinds() throws {
        #expect(try FirebaseJSON.parse("1") == .int(1))
        #expect(try FirebaseJSON.parse("1.0") == .double(1))
        #expect(try FirebaseJSON.parse("[1, 2.5]") == .array([.int(1), .double(2.5)]))
        #expect(try FirebaseJSON.parse("9007199254740993") == .int(9_007_199_254_740_993))
        #expect(try FirebaseJSON.parse("true") == .bool(true))
        #expect(try FirebaseJSON.parse("0") == .int(0))
    }

    @Test("Text is deterministic, sorted and escaped")
    func text() throws {
        let value = try FirebaseJSON.parse(#"{"b": 1, "a": "x\"y\n", "c": [true, null, 1.5]}"#)
        #expect(value.text() == #"{"a":"x\"y\n","b":1,"c":[true,null,1.5]}"#)
        #expect(FirebaseJSON.double(3).text() == "3.0")
        #expect(FirebaseJSON.object([:]).text() == "{}")
    }

    @Test("Pretty text indents nested values")
    func pretty() {
        let value = FirebaseJSON.object(["a": .array([.int(1)])])
        #expect(value.text(pretty: true) == "{\n  \"a\": [\n    1\n  ]\n}")
    }

    @Test("Invalid JSON throws a configuration-free malformed error")
    func invalid() {
        #expect(throws: FirebaseError.self) { try FirebaseJSON.parse("{nope") }
    }

    @Test("Round trip through text keeps the value")
    func roundTrip() throws {
        let original = FirebaseJSON.object([
            "n": .int(-42), "d": .double(0.1), "s": .string("é \u{1F600}"), "z": .null, "l": .array([.bool(false)])
        ])
        #expect(try FirebaseJSON.parse(original.text()) == original)
    }
}
