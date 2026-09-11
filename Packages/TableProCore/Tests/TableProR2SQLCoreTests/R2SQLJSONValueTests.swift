import Foundation
import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL JSON values")
struct R2SQLJSONValueTests {
    private func decode(_ json: String) throws -> R2SQLJSONValue {
        try JSONDecoder().decode(R2SQLJSONValue.self, from: Data(json.utf8))
    }

    @Test("Numbers keep every digit", arguments: [
        "12345678901234567.89",
        "99999999999999999999999999999999999999",
        "18446744073709551615",
        "9007199254740993",
        "-9223372036854775808",
        "0.1"
    ])
    func exactNumbers(literal: String) throws {
        #expect(try decode(literal).jsonText == literal)
    }

    @Test("A number no Decimal can hold is a decoding error, not NULL")
    func outOfRangeNumberThrows() {
        #expect(throws: DecodingError.self) { try decode("1e400") }
    }

    @Test("Booleans stay booleans and never read as numbers")
    func booleans() throws {
        #expect(try decode("true") == .bool(true))
        #expect(try decode("1") == .number(1))
    }

    @Test("Nested values render as JSON without re-encoding their numbers")
    func nestedText() throws {
        let value = try decode(#"{"y":0.1,"x":[1,"a\"b",null,false]}"#)
        #expect(value.jsonText == #"{"x":[1,"a\"b",null,false],"y":0.1}"#)
    }
}
