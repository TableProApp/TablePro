import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP Base64 Sentinel")
struct MCPBase64SentinelTests {
    @Test("Spec encoding examples round-trip exactly")
    func specEncodingExamples() {
        let vectors: [(String, String)] = [
            ("us-west1", "us-west1"),
            ("Hello, 世界", "=?base64?SGVsbG8sIOS4lueVjA==?="),
            (" padded ", "=?base64?IHBhZGRlZCA=?="),
            ("line1\nline2", "=?base64?bGluZTEKbGluZTI=?="),
            ("=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        ]
        for (original, expected) in vectors {
            #expect(MCPBase64Sentinel.encodeIfNeeded(original) == expected)
            #expect(MCPBase64Sentinel.decodeIfNeeded(expected) == original)
        }
    }

    @Test("Sentinel markers are case sensitive")
    func markersAreCaseSensitive() {
        #expect(MCPBase64Sentinel.decode("=?BASE64?SGk=?=") == nil)
        #expect(MCPBase64Sentinel.isSentinel("=?base64?SGk=?="))
        #expect(!MCPBase64Sentinel.isSentinel("=?base64?"))
    }

    @Test("Malformed payloads decode to nil")
    func malformedPayload() {
        #expect(MCPBase64Sentinel.decode("=?base64?zzz?=") == nil)
        #expect(MCPBase64Sentinel.decodeIfNeeded("plain value") == "plain value")
    }

    @Test("Header safety follows the visible ASCII rule")
    func headerSafety() {
        #expect(MCPBase64Sentinel.isHeaderSafe("plain-value"))
        #expect(!MCPBase64Sentinel.isHeaderSafe(" leading"))
        #expect(!MCPBase64Sentinel.isHeaderSafe("trailing "))
        #expect(!MCPBase64Sentinel.isHeaderSafe("with\nnewline"))
        #expect(!MCPBase64Sentinel.isHeaderSafe("=?base64?literal?="))
    }

    @Test("Every spec vector round-trips through encode and decode")
    func vectorsRoundTrip() {
        let originals = ["us-west1", "Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?="]
        for original in originals {
            let encoded = MCPBase64Sentinel.encodeIfNeeded(original)
            #expect(MCPBase64Sentinel.decodeIfNeeded(encoded) == original)
        }
    }

    @Test("A plain ASCII value is left untouched")
    func plainAsciiIsNotEncoded() {
        for value in ["us-west1", "run_query", "tablepro://c/1/table/users", "42", "true"] {
            #expect(MCPBase64Sentinel.encodeIfNeeded(value) == value)
        }
    }

    @Test("A value matching the sentinel pattern is encoded even though it is plain ASCII")
    func sentinelLookalikeIsEncoded() {
        let literal = "=?base64?literal?="
        #expect(!MCPBase64Sentinel.isHeaderSafe(literal))
        #expect(MCPBase64Sentinel.encodeIfNeeded(literal) == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        #expect(MCPBase64Sentinel.decode("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=") == literal)
    }

    @Test("An empty payload decodes to an empty string")
    func emptyPayload() {
        #expect(MCPBase64Sentinel.encode("") == "=?base64??=")
        #expect(MCPBase64Sentinel.decode("=?base64??=") == "")
    }

    @Test("A value shorter than the markers is not a sentinel")
    func shortValuesAreNotSentinels() {
        #expect(!MCPBase64Sentinel.isSentinel("=?="))
        #expect(!MCPBase64Sentinel.isSentinel("?="))
        #expect(!MCPBase64Sentinel.isSentinel(""))
        #expect(MCPBase64Sentinel.decode("=?=") == nil)
    }

    @Test("A payload that is not valid UTF-8 decodes to nil")
    func nonUtf8PayloadDecodesToNil() {
        let payload = Data([0xFF, 0xFE, 0xFD]).base64EncodedString()
        #expect(MCPBase64Sentinel.decode("=?base64?\(payload)?=") == nil)
    }

    @Test("An interior tab stays plain while other control characters force encoding")
    func controlCharactersForceEncoding() {
        #expect(MCPBase64Sentinel.encodeIfNeeded("a\tb") == "a\tb")
        #expect(!MCPBase64Sentinel.isHeaderSafe("a\u{0007}b"))
        #expect(!MCPBase64Sentinel.isHeaderSafe("a\rb"))
        #expect(MCPBase64Sentinel.decodeIfNeeded(MCPBase64Sentinel.encodeIfNeeded("a\rb")) == "a\rb")
    }

    @Test("Non-ASCII names are carried Base64-wrapped")
    func nonAsciiNames() {
        for name in ["查询", "größer", "🚀 launch"] {
            let encoded = MCPBase64Sentinel.encodeIfNeeded(name)
            #expect(encoded.hasPrefix(MCPBase64Sentinel.prefix))
            #expect(encoded.hasSuffix(MCPBase64Sentinel.suffix))
            #expect(MCPBase64Sentinel.decodeIfNeeded(encoded) == name)
        }
    }
}
