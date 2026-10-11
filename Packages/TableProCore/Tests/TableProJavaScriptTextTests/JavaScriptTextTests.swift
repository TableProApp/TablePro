//
//  JavaScriptTextTests.swift
//  TableProJavaScriptTextTests
//

import Foundation
import JavaScriptCore
import Testing

@testable import TableProJavaScriptText

struct JavaScriptTextTests {
    private static let lineTerminators: [Unicode.Scalar] = [
        "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"
    ]

    private static let mixedName = "a\u{2028}b\u{2029}c\u{85}d\u{0B}e\u{0C}f\"g\\h\ni\rj\tk\u{7F}l\u{9F}m\u{00}n😀o"

    private static func containsRawLineTerminator(_ text: String) -> Bool {
        text.unicodeScalars.contains { lineTerminators.contains($0) }
    }

    @Test("Each line-breaking character has the escape the MongoDB driver's statements use")
    func escapeSpelling() {
        let expected: [(Unicode.Scalar, String)] = [
            ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t"), ("\u{00}", "\\u0000"), ("\u{0B}", "\\u000b"),
            ("\u{0C}", "\\u000c"), ("\u{1F}", "\\u001f"), ("\u{7F}", "\\u007f"), ("\u{85}", "\\u0085"),
            ("\u{9F}", "\\u009f"), ("\u{2028}", "\\u2028"), ("\u{2029}", "\\u2029")
        ]
        for (scalar, escape) in expected {
            #expect(JavaScriptText.lineBreakingEscape(scalar) == escape, "U+\(String(scalar.value, radix: 16))")
        }
        for scalar: Unicode.Scalar in ["a", " ", "\"", "\\", "\u{A0}", "\u{E9}", "\u{2027}", "\u{202A}", "\u{1F600}"] {
            #expect(JavaScriptText.lineBreakingEscape(scalar) == nil, "U+\(String(scalar.value, radix: 16))")
        }
    }

    /// The literal is built from UTF-8 bytes for speed, so it has to agree with the scalar rule
    /// for every character, not only the ones picked for a test.
    @Test("A string literal escapes exactly what the scalar rule escapes, for every BMP character")
    func literalAgreesWithScalarRuleEverywhere() {
        var mismatches: [UInt32] = []
        let scalars = (0 ... 0xFFFF).compactMap(Unicode.Scalar.init) + ["\u{10000}", "\u{1F600}", "\u{10FFFF}"]
        for scalar in scalars {
            let body: String
            switch scalar {
            case "\"": body = "\\\""
            case "\\": body = "\\\\"
            default: body = JavaScriptText.lineBreakingEscape(scalar) ?? String(scalar)
            }
            if JavaScriptText.stringLiteral("x\(String(scalar))y") != "\"x\(body)y\"" {
                mismatches.append(scalar.value)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    }

    @Test("A string literal holds no raw line terminator and reads back as the name through JSON")
    func literalRoundTripsThroughJSON() throws {
        let literal = JavaScriptText.stringLiteral(Self.mixedName)
        #expect(!Self.containsRawLineTerminator(literal))
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded.unicodeScalars.elementsEqual(Self.mixedName.unicodeScalars))
    }

    @Test("A string literal reads back as the name through JavaScriptCore's JSON.parse")
    func literalRoundTripsThroughJavaScriptCore() throws {
        let context = try #require(JSContext())
        let parse = try #require(context.evaluateScript("JSON.parse"))
        for name in [Self.mixedName, "a\u{2028}b", "a\u{2029}b", "a\u{85}b", "plain"] {
            let literal = JavaScriptText.stringLiteral(name)
            let parsed = parse.call(withArguments: [literal])
            #expect(context.exception == nil)
            #expect(parsed?.toString().unicodeScalars.elementsEqual(name.unicodeScalars) == true)
        }
    }

    @Test("A bridged string takes the same path as a native one")
    func bridgedStringMatchesNative() {
        let native = "a\u{2028}b\"c"
        let bridged = NSString(string: native) as String
        #expect(JavaScriptText.stringLiteral(bridged) == JavaScriptText.stringLiteral(native))
        #expect(JavaScriptText.stringLiteral(native) == "\"a\\u2028b\\\"c\"")
    }

    @Test("A comment stays on one line whatever line terminator the text holds")
    func commentHoldsNoLineTerminator() {
        for terminator in Self.lineTerminators {
            let comment = JavaScriptText.lineComment("Collection: a\(String(terminator))b")
            #expect(!Self.containsRawLineTerminator(comment), "U+\(String(terminator.value, radix: 16))")
            #expect(comment.hasPrefix("// Collection: a\\"))
        }
    }

    @Test("A comment keeps printable text as it is, quotes and a block-comment end included")
    func commentKeepsPrintableText() {
        #expect(JavaScriptText.lineComment("a */ \"b\" 'c' \\d tên") == "// a */ \"b\" 'c' \\d tên")
        #expect(JavaScriptText.lineComment("") == "//")
    }

    @Test("Only an ASCII identifier is plain")
    func plainIdentifiers() {
        for name in ["orders", "order_2", "_x", "A"] {
            #expect(JavaScriptText.isPlainIdentifier(name), "\(name)")
        }
        for name in ["", "2025", "tên", "a b", "a;b", "a.b", "a$b", "a\u{0D4E}(\u{0D4E})", "a\u{2028}b"] {
            #expect(!JavaScriptText.isPlainIdentifier(name), "\(name)")
        }
    }
}
