import Foundation
import TableProTabularIO
import Testing
@testable import TableProMobile

struct JSONValidationTests {
    private func failing(_ text: String) throws -> JSONValidation.Failure {
        let reported: JSONValidation.Failure? = if case .failure(let found) = JSONValidation.check(text) { found } else { nil }
        return try #require(reported, "\(text) passed")
    }

    @Test("valid text passes with the kind of its top value")
    func validTextPasses() {
        #expect(JSONValidation.check(#"{"a":[1,2]}"#) == .success(.object))
        #expect(JSONValidation.check(" [ ] ") == .success(.array))
        #expect(JSONValidation.check("-1.5e3") == .success(.number))
        #expect(JSONValidation.check(#""x""#) == .success(.text))
        #expect(JSONValidation.check("null") == .success(.null))
    }

    @Test("the issue's document without its last brace fails at line 1, column 55")
    func missingBraceReportsTheEnd() throws {
        let failure = try failing(#"{"user":{"name":"a","emails":["x@y.z"]},"tags":[1,2,3]"#)
        #expect(failure.byteOffset == 54)
        #expect(failure.line == 1)
        #expect(failure.column == 55)
        #expect(failure.utf16Offset == 54)
        #expect(failure.reason == String(localized: "The JSON ends before it is complete."))
        #expect(failure.message == String(format: String(localized: "Line %lld, column %lld: %@"), 1, 55, failure.reason))
    }

    @Test("a line counts from the last line break before the error")
    func multiLineText() throws {
        let failure = try failing("{\n  \"a\": 1,\n  \"b\": tru\n}")
        #expect(failure.byteOffset == 19)
        #expect(failure.line == 3)
        #expect(failure.column == 8)
        #expect(failure.reason == String(localized: "Expected true, false or null."))
    }

    @Test("CRLF is one line break")
    func carriageReturnLineFeed() throws {
        let failure = try failing("[\r\n1,\r\n]")
        #expect(failure.line == 3)
        #expect(failure.column == 1)
        #expect(failure.byteOffset == 7)
        #expect(failure.utf16Offset == 7)
    }

    @Test("the column counts characters, the offsets count bytes and UTF-16 units")
    func nonASCIIColumns() throws {
        let wide = try failing("{\"\u{540D}\u{524D}\": \"\u{E9}\", x}")
        #expect(wide.byteOffset == 17)
        #expect(wide.column == 13)
        #expect(wide.utf16Offset == 12)

        let emoji = try failing("[\"\u{1F44D}\u{1F3FD}\", ]")
        #expect(emoji.byteOffset == 13)
        #expect(emoji.column == 7)
        #expect(emoji.utf16Offset == 9)
        #expect(emoji.reason == String(localized: "Unexpected character."))
    }

    @Test("each error names its own reason")
    func reasons() throws {
        #expect(try failing("01").reason == String(localized: "Invalid number."))
        #expect(try failing("[1}").reason == String(localized: "This bracket does not close the one that is open."))
        #expect(try failing("{} x").reason == String(localized: "Extra text after the JSON value."))
        #expect(try failing("\"a\tb\"").reason == String(localized: "A string cannot hold a line break, tab or other control character."))
        #expect(try failing(#""\q""#).reason == String(localized: "Invalid escape sequence."))
        #expect(try failing("{} x").column == 4)
        #expect(try failing("\"a\tb\"").column == 3)
    }

    @Test("empty and blank text fail at the end")
    func emptyText() throws {
        #expect(try failing("").column == 1)
        #expect(try failing("  \n").line == 2)
    }
}
