//
//  MQLExportHelpersTests.swift
//  FormatPluginTests
//

import Foundation
import JavaScriptCore
import TableProPluginKit
import Testing

struct MQLExportHelpersTests {
    private static let uuid = "8cd003eb-4a25-4324-9332-88fce2da0d1a"
    private static let lineTerminators: [Unicode.Scalar] = [
        "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"
    ]

    @Test("Canonical scalar types stay explicit", arguments: [
        #"{"$oid":"507f1f77bcf86cd799439011"}"#,
        #"{"$numberLong":"9007199254740993"}"#,
        #"{"$numberDouble":"1.0"}"#,
        #"{"$numberDouble":"NaN"}"#,
        #"{"$numberDecimal":"1847.270000000000000000000000001"}"#,
        #"{"$date":{"$numberLong":"1767225600123"}}"#,
        #"{"$binary":{"base64":"JEMlSusD0IwaDdri/Igykw==","subType":"03"}}"#
    ])
    func canonicalScalarTypes(json: String) throws {
        let written = try MQLExportHelpers.canonicalValue(json)
        #expect(written.hasPrefix("EJSON.parse("))
        #expect(written.hasSuffix(", {relaxed: false})"))
    }

    @Test("Text shaped like another type remains text", arguments: ["true", "42", "null", "{\"a\":1}", "UUID(\"x\")"])
    func stringValuesStayStrings(value: String) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(try MQLExportHelpers.canonicalValue(json) == json)
    }

    @Test("A document keeps numeric keys, __proto__ and stored null fields")
    func orderedDocument() throws {
        let value = try MQLExportHelpers.canonicalValue(#"{"z":null,"10":"a","2":"b","__proto__":"c"}"#)
        #expect(value == #"new Map([["z", null], ["10", "a"], ["2", "b"], ["__proto__", "c"]])"#)
    }

    @Test("Nested canonical values are not cut to the display length")
    func longNestedValue() throws {
        let text = String(repeating: "x", count: 20_000)
        let value = try MQLExportHelpers.canonicalValue("{\"child\":[\"\(text)\",{\"$numberLong\":\"5\"}]}")
        #expect(value.contains(text))
        #expect(value.contains("EJSON.parse("))
    }

    @Test("Only JSON data is accepted on the document path", arguments: ["ObjectId(\"x\")", "{}; db.users.drop()", "undefined", "NaN"])
    func rejectsScriptValue(value: String) {
        #expect(throws: (any Error).self) { try MQLExportHelpers.canonicalValue(value) }
    }

    @Test("A collection is addressed as db.<name> only when mongosh would resolve that to it")
    func collectionAccessorAvoidsShadowedNames() {
        #expect(MQLExportHelpers.collectionAccessor(for: "users") == "db.users")
        #expect(MQLExportHelpers.collectionAccessor(for: "stats") == "db.getCollection(\"stats\")")
        #expect(MQLExportHelpers.collectionAccessor(for: "my.data") == "db.getCollection(\"my.data\")")
        #expect(MQLExportHelpers.collectionAccessor(for: "2024") == "db.getCollection(\"2024\")")
    }

    @Test("The export spells a collection the way the shared accessor does")
    func accessorAgreesWithSharedAccessor() {
        let names = ["users", "order_2", "stats", "__proto", "my.data", "2024", "tên", "a\u{0D4E}(\u{0D4E})", "a\"b", "a\u{2028}b", ""]
        for name in names {
            #expect(MQLExportHelpers.collectionAccessor(for: name) == MongoCollectionAccessor.expression(for: name), "\(name)")
        }
        #expect(MQLExportHelpers.collectionAccessor(for: "a\u{2028}b") == "db.getCollection(\"a\\u2028b\")")
    }

    @Test("A header comment stays on one line whatever line terminator the name holds")
    func headerCommentStaysOnOneLine() {
        for terminator in Self.lineTerminators {
            let header = MQLExportHelpers.headerComment(label: "Collection", name: "a\(String(terminator))b")
            #expect(!header.unicodeScalars.contains { Self.lineTerminators.contains($0) }, "U+\(terminator.value)")
            #expect(header.hasPrefix("// Collection: a\\"))
        }
        #expect(MQLExportHelpers.headerComment(label: "Database", name: "shop */ 'x'") == "// Database: shop */ 'x'")
    }

    @Test("Field names and strings escape line separators")
    func nestedDocumentEscapesSeparators() throws {
        let value = try MQLExportHelpers.canonicalValue("{\"a\u{2028}b\":\"c\u{85}d\"}")
        #expect(value == "new Map([[\"a\\u2028b\", \"c\\u0085d\"]])")
        #expect(!value.unicodeScalars.contains { Self.lineTerminators.contains($0) })
    }
    @Test("Dates outside the shell range fail instead of becoming the Unix epoch", arguments: [
        "9223372036854775807", "-9223372036854775808", "8640000000000001"
    ])
    func refusesUnrepresentableDate(digits: String) {
        #expect(throws: (any Error).self) {
            try MQLExportHelpers.canonicalValue("{\"$date\":{\"$numberLong\":\"\(digits)\"}}")
        }
    }

    @Test("An insert command checks both command and per-document errors", arguments: [
        #"{"ok":0,"errmsg":"failed"}"#,
        #"{"ok":1,"writeErrors":[{"code":11000}]}"#,
        #"{"ok":1,"writeConcernError":{"code":64}}"#
    ])
    func writeFailuresStopScript(reply: String) throws {
        let context = try #require(JSContext())
        context.evaluateScript("var db = {runCommand: function() {return \(reply);}}; var EJSON = {stringify: JSON.stringify};")
        context.evaluateScript(MQLExportHelpers.insertCommand(collection: "people", documents: []))
        #expect(context.exception != nil)
    }

}
