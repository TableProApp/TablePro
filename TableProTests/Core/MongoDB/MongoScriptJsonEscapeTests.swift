//
//  MongoScriptJsonEscapeTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoScriptJsonEscapeTests {
    @Test("Member names are decoded, so a quote or a backslash in a field name survives")
    func memberNamesAreDecoded() {
        let members = MongoScriptJson.members(of: "{\"a\\\"b\": 1, \"c\\\\d\": 2, \"e\\u00e9\": 3, \"f\\ng\": 4}")

        #expect(members.map(\.key) == ["a\"b", "c\\d", "e\u{e9}", "f\ng"])
        #expect(members.map(\.value) == ["1", "2", "3", "4"])
    }

    @Test("A member is found by its decoded name")
    func memberByDecodedName() {
        #expect(MongoScriptJson.member(of: "{\"x\": 0, \"a\\\"b\": {\"c\": 1}}", key: "a\"b") == "{\"c\": 1}")
    }

    @Test("A surrogate pair decodes to the character it encodes")
    func surrogatePair() {
        #expect(MongoScriptJson.members(of: "{\"\\ud83d\\ude00\": 1}").map(\.key) == ["\u{1F600}"])
    }

    @Test("A string is written with every character that ends a line or cannot be seen escaped, and reads back whole")
    func jsonStringEscapesLineEndings() throws {
        let value = "a\nb\rc\td\u{0B}e\u{85}f\u{2028}g\u{2029}h\u{7F}i\u{9F}j\"k\\l */ m' n"
        let written = MongoScriptJson.jsonString(value)

        #expect(written == #""a\nb\rc\td\u000be\u0085f\u2028g\u2029h\u007fi\u009fj\"k\\l */ m' n""#)
        #expect(!written.contains { $0.isNewline })
        #expect(try JSONDecoder().decode(String.self, from: Data(written.utf8)) == value)
        #expect(MongoScriptJson.decodedString(written) == value)
    }

    @Test("A string value's text decodes to the string, and anything else to nil")
    func decodedString() {
        #expect(MongoScriptJson.decodedString("\"x\\ny\"") == "x\ny")
        #expect(MongoScriptJson.decodedString(" \"a\\\"b\" ") == "a\"b")
        #expect(MongoScriptJson.decodedString("1") == nil)
        #expect(MongoScriptJson.decodedString("{ \"a\" : 1 }") == nil)
        #expect(MongoScriptJson.decodedString("\"unterminated") == nil)
    }
}
