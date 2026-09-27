//
//  MongoDocumentTextTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoDocumentTextTests {
    @Test("A document keeps its fields in the order they were written")
    func keepsOrder() throws {
        let document = try MongoDocumentText(parsing: #"{"zeta": 1, "2": "two", "alpha": {"b": 1, "a": 2}}"#)
        #expect(document.members.map(\.key) == ["zeta", "2", "alpha"])
        #expect(document.compactText == #"{"zeta":1,"2":"two","alpha":{"b":1,"a":2}}"#)
    }

    @Test("Every JSON value kind reads back as the same text")
    func valueKinds() throws {
        let text = #"{"s":"a\"b\\c\né","n":-1.5e+10,"z":0,"t":true,"f":false,"x":null,"a":[1,[],{}],"o":{}}"#
        let document = try MongoDocumentText(parsing: text)
        let reread = try MongoDocumentText(parsing: document.compactText)
        #expect(reread == document)
        #expect(document.members.first { $0.key == "s" }?.value == .string("a\"b\\c\né"))
    }

    @Test("A string escape for a character outside the BMP reads as one character")
    func surrogatePair() throws {
        let document = try MongoDocumentText(parsing: #"{"emoji": "😀"}"#)
        #expect(document.members.first { $0.key == "emoji" }?.value == .string("😀"))
    }

    @Test("Empty text is refused")
    func empty() {
        #expect(throws: MongoDocumentText.Refusal.empty) { try MongoDocumentText(parsing: "  \n ") }
    }

    @Test("An array or a scalar is not a document")
    func notAnObject() {
        #expect(throws: MongoDocumentText.Refusal.notAnObject) { try MongoDocumentText(parsing: "[{\"a\": 1}]") }
        #expect(throws: MongoDocumentText.Refusal.notAnObject) { try MongoDocumentText(parsing: "42") }
    }

    @Test("A second document after the first is refused rather than dropped")
    func trailingDocument() {
        #expect(throws: MongoDocumentText.Refusal.trailingContent) {
            try MongoDocumentText(parsing: #"{"a": 1} {"b": 2}"#)
        }
    }

    @Test("A repeated field is refused at any depth")
    func duplicateFields() {
        #expect(throws: MongoDocumentText.Refusal.duplicateField("a")) {
            try MongoDocumentText(parsing: #"{"a": 1, "a": 2}"#)
        }
        #expect(throws: MongoDocumentText.Refusal.duplicateField("k")) {
            try MongoDocumentText(parsing: #"{"outer": [{"k": 1, "k": 2}]}"#)
        }
    }

    @Test("An empty, blank, dotted or $-prefixed name reads as written, since an insert stores each one")
    func namesAreReadAsWritten() throws {
        let text = #"{"":1,"   ":2,"a.b":3,"$set":{"x":4},"$oid":"507f1f77bcf86cd799439011","n":{"":5}}"#
        let document = try MongoDocumentText(parsing: text)
        #expect(document.members.map(\.key) == ["", "   ", "a.b", "$set", "$oid", "n"])
        #expect(document.compactText == text)

        let wrapped = try MongoDocumentText(parsing: #"{"_id": {"$oid": "507f1f77bcf86cd799439011"}}"#)
        #expect(wrapped.members.count == 1)
    }

    @Test("A field named \"\" is held to the rule against repeated fields")
    func duplicateEmptyName() {
        #expect(throws: MongoDocumentText.Refusal.duplicateField("")) {
            try MongoDocumentText(parsing: #"{"": 1, "": 2}"#)
        }
    }

    @Test("Nesting deeper than MongoDB allows is refused without exhausting the stack")
    func depthLimit() throws {
        let allowed = String(repeating: "{\"a\":", count: MongoDocumentText.maximumDepth - 1) + "1"
            + String(repeating: "}", count: MongoDocumentText.maximumDepth - 1)
        _ = try MongoDocumentText(parsing: allowed)

        let hostile = "{\"a\":" + String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000) + "}"
        #expect(throws: MongoDocumentText.Refusal.tooDeep) { try MongoDocumentText(parsing: hostile) }
    }

    @Test("Text that is not JSON is refused with its line and column")
    func malformed() {
        #expect(throws: MongoDocumentText.Refusal.malformed(line: 2, column: 3)) {
            try MongoDocumentText(parsing: "{\n  name: \"x\"\n}")
        }
        #expect(throws: MongoDocumentText.Refusal.malformed(line: 1, column: 9)) {
            try MongoDocumentText(parsing: #"{"a": 1,}"#)
        }
    }

    @Test("Syntax JSON does not have is refused", arguments: [
        #"{"a": 'single'}"#,
        #"{"a": 01}"#,
        #"{"a": 1.}"#,
        #"{"a": NaN}"#,
        #"{"a": ObjectId("507f1f77bcf86cd799439011")}"#,
        "{\"a\": \"raw\u{0001}control\"}",
        #"{"a": "\x41"}"#,
        #"{"a": 1 // comment"#
    ])
    func refusedSyntax(_ text: String) {
        #expect(throws: MongoDocumentText.Refusal.self) { try MongoDocumentText(parsing: text) }
    }

    @Test("Quoting escapes what a JSON string cannot hold raw")
    func quoting() {
        #expect(MongoDocumentText.quoted("a\"b\\c\n\u{0001}\u{2028}") == #""a\"b\\c\n\u0001\u2028""#)
    }
}
