//
//  MongoDBShellTextTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDBShellTextTests {
    @Test("A comment keeps a plain name as it is")
    func plainCommentIsUnchanged() {
        #expect(MongoDBShellText.comment("Collection: people") == "// Collection: people")
        #expect(MongoDBShellText.comment("View: người dùng") == "// View: người dùng")
    }

    @Test("Every character that ends a line or cannot be seen is written as its escape in a comment")
    func commentEscapesLineEndings() {
        let cases: [(name: String, spelled: String)] = [
            ("a\nb", "a\\nb"),
            ("a\rb", "a\\rb"),
            ("a\r\nb", "a\\r\\nb"),
            ("a\tb", "a\\tb"),
            ("a\u{2028}b", "a\\u2028b"),
            ("a\u{2029}b", "a\\u2029b"),
            ("a\u{85}b", "a\\u0085b"),
            ("a\u{0B}b", "a\\u000bb"),
            ("a\u{0C}b", "a\\u000cb"),
            ("a\u{00}b", "a\\u0000b"),
            ("a\u{7F}b", "a\\u007fb")
        ]
        for testCase in cases {
            let line = MongoDBShellText.comment("View: \(testCase.name)")

            #expect(line == "// View: \(testCase.spelled)", "\(testCase.name.debugDescription)")
            #expect(!line.contains { $0.isNewline }, "\(testCase.name.debugDescription)")
        }
    }

    @Test("A block comment closer and quotes cannot end a line comment, so they stay as they are")
    func commentKeepsCloserAndQuotes() {
        #expect(MongoDBShellText.comment("View: a */ b \" c ' d") == "// View: a */ b \" c ' d")
    }

    @Test("A name made of identifier characters is reached with a dot")
    func identifierNamesUseTheDot() {
        #expect(MongoDBShellText.collection("people") == "db.people")
        #expect(MongoDBShellText.collection("_audit2") == "db._audit2")
        #expect(MongoDBShellText.collection("người_dùng") == "db.người_dùng")
    }

    @Test("Any other name is reached through getCollection, escaped as a string")
    func otherNamesUseGetCollection() {
        let cases: [(name: String, expression: String)] = [
            ("stats", "db.getCollection(\"stats\")"),
            ("2024", "db.getCollection(\"2024\")"),
            ("a.b", "db.getCollection(\"a.b\")"),
            ("a b", "db.getCollection(\"a b\")"),
            ("a\"b", "db.getCollection(\"a\\\"b\")"),
            ("a\nb", "db.getCollection(\"a\\nb\")"),
            ("a\u{2028}b", "db.getCollection(\"a\\u2028b\")"),
            ("a\u{2029}b", "db.getCollection(\"a\\u2029b\")"),
            ("a\u{0D4E};b", "db.getCollection(\"a\u{0D4E};b\")")
        ]
        for testCase in cases {
            #expect(MongoDBShellText.collection(testCase.name) == testCase.expression, "\(testCase.name.debugDescription)")
        }
    }
}
