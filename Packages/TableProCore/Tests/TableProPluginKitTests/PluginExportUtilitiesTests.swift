//
//  PluginExportUtilitiesTests.swift
//  TableProPluginKitTests
//

import Foundation
import JavaScriptCore
import Testing

@testable import TableProPluginKit

struct PluginExportUtilitiesTests {
    private static let separators = "a\u{85}b\u{2028}c\u{2029}d"

    @Test("NEL, the line separator and the paragraph separator are escaped")
    func escapesLineSeparators() {
        #expect(PluginExportUtilities.escapeJSONString(Self.separators) == "a\\u0085b\\u2028c\\u2029d")
    }

    @Test("The escapes JSON export already wrote are unchanged")
    func existingEscapesUnchanged() {
        #expect(PluginExportUtilities.escapeJSONString("q\"b\\n\nr\rt\tb\u{08}f\u{0C}c\u{01}u\u{1F}")
            == "q\\\"b\\\\n\\nr\\rt\\tb\\bf\\fc\\u0001u\\u001F")
    }

    @Test("Characters that share a lead byte with a separator pass through as they are")
    func neighboursOfSeparatorsUnchanged() {
        let text = "\u{84}\u{86}\u{A0}\u{C0}\u{2027}\u{202A}\u{2030}\u{20AC}tên 東京 😀"
        #expect(PluginExportUtilities.escapeJSONString(text) == text)
    }

    @Test("A bridged string escapes the same way as a native one")
    func bridgedStringMatchesNative() {
        let bridged = NSString(string: Self.separators) as String
        #expect(PluginExportUtilities.escapeJSONString(bridged) == "a\\u0085b\\u2028c\\u2029d")
    }

    @Test("The escaped text reads back as the original through JSON and JavaScriptCore")
    func roundTripsThroughJSONAndJavaScriptCore() throws {
        let name = "x\"y\\z\n\u{0B}\u{0C}\(Self.separators)😀"
        let literal = "\"\(PluginExportUtilities.escapeJSONString(name))\""
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded.unicodeScalars.elementsEqual(name.unicodeScalars))

        let context = try #require(JSContext())
        let parsed = context.evaluateScript("JSON.parse")?.call(withArguments: [literal])
        #expect(context.exception == nil)
        #expect(parsed?.toString().unicodeScalars.elementsEqual(name.unicodeScalars) == true)
    }

    @Test("A collection reached through getCollection has its separators escaped")
    func accessorEscapesSeparators() {
        #expect(MongoCollectionAccessor.expression(for: "a\u{2028}b") == "db.getCollection(\"a\\u2028b\")")
        #expect(MongoCollectionAccessor.unescape("a\\u2028b") == "a\u{2028}b")
    }
}
