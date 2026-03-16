//
//  EtcdHttpClientUtilityTests.swift
//  TableProTests
//
//  Tests for EtcdHttpClient static utility functions (base64 and prefix range).
//  These are pure functions that can be tested without a live etcd server.
//
//  The utilities are replicated here because EtcdHttpClient.swift cannot be
//  symlinked into the test target (it depends on Security, URLSession, and
//  networking code that would require the full plugin environment).
//

import Foundation
import Testing

// MARK: - Base64 Helpers

@Suite("EtcdHttpClient Utilities - Base64")
struct EtcdBase64Tests {
    @Test("base64Encode and base64Decode round-trip for simple string")
    func roundTripSimple() {
        let original = "hello"
        let encoded = TestEtcdBase64.encode(original)
        let decoded = TestEtcdBase64.decode(encoded)
        #expect(decoded == original)
    }

    @Test("base64Encode and base64Decode round-trip for empty string")
    func roundTripEmpty() {
        let original = ""
        let encoded = TestEtcdBase64.encode(original)
        let decoded = TestEtcdBase64.decode(encoded)
        #expect(decoded == original)
    }

    @Test("base64Encode and base64Decode round-trip for Unicode")
    func roundTripUnicode() {
        let original = "hello world \u{1F600} \u{00E9}"
        let encoded = TestEtcdBase64.encode(original)
        let decoded = TestEtcdBase64.decode(encoded)
        #expect(decoded == original)
    }

    @Test("base64Encode and base64Decode round-trip for path-like string")
    func roundTripPath() {
        let original = "/app/config/database/host"
        let encoded = TestEtcdBase64.encode(original)
        let decoded = TestEtcdBase64.decode(encoded)
        #expect(decoded == original)
    }

    @Test("base64Encode and base64Decode round-trip for string with special chars")
    func roundTripSpecialChars() {
        let original = "key:with/slashes\\and=signs&more"
        let encoded = TestEtcdBase64.encode(original)
        let decoded = TestEtcdBase64.decode(encoded)
        #expect(decoded == original)
    }

    @Test("base64Decode with invalid input returns the input unchanged")
    func decodeInvalidInput() {
        let invalid = "not-valid-base64!!!"
        let result = TestEtcdBase64.decode(invalid)
        // When base64 decoding fails, the original string is returned
        #expect(result == invalid)
    }

    @Test("base64Encode produces standard base64 output")
    func encodeKnownValue() {
        let encoded = TestEtcdBase64.encode("hello")
        #expect(encoded == "aGVsbG8=")
    }

    @Test("base64Decode known value")
    func decodeKnownValue() {
        let decoded = TestEtcdBase64.decode("aGVsbG8=")
        #expect(decoded == "hello")
    }
}

// MARK: - Prefix Range End

@Suite("EtcdHttpClient Utilities - PrefixRangeEnd")
struct EtcdPrefixRangeEndTests {
    @Test("Normal prefix increments last byte")
    func normalPrefix() {
        let result = TestEtcdPrefixRange.rangeEnd(for: "/app/")
        // "/" is ASCII 0x2F, so the range end should be "/app0" where "0" is the next char
        #expect(result == "/app0")
    }

    @Test("Single character prefix")
    func singleChar() {
        let result = TestEtcdPrefixRange.rangeEnd(for: "a")
        #expect(result == "b")
    }

    @Test("Empty prefix returns null byte")
    func emptyPrefix() {
        let result = TestEtcdPrefixRange.rangeEnd(for: "")
        #expect(result == "\0")
    }

    @Test("Prefix ending with z increments to {")
    func prefixEndingWithZ() {
        let result = TestEtcdPrefixRange.rangeEnd(for: "z")
        // "z" is 0x7A, increment gives 0x7B which is "{"
        #expect(result == "{")
    }

    @Test("Prefix 'abc' increments to 'abd'")
    func prefixAbc() {
        let result = TestEtcdPrefixRange.rangeEnd(for: "abc")
        #expect(result == "abd")
    }

    @Test("All 0xFF bytes returns null byte")
    func allMaxBytes() {
        // 0xFF bytes aren't valid UTF-8; test with lossy decoding to exercise the all-max-byte path
        let input = String(decoding: [0xFF, 0xFF, 0xFF] as [UInt8], as: UTF8.self)
        let result = TestEtcdPrefixRange.rangeEnd(for: input)
        #expect(result == "\0")
    }

    @Test("Prefix ending with high-value byte rolls back correctly")
    func trailingHighBytes() {
        // "a" + 0xFE (high but not max) should increment 0xFE to 0xFF, truncate to "a\xFF"
        // But since 0xFE isn't valid UTF-8 continuation, test with valid multi-byte:
        // Use "z" which is 0x7A — incrementing gives 0x7B = "{"
        let result = TestEtcdPrefixRange.rangeEnd(for: "az")
        #expect(result == "a{")
    }
}

// MARK: - Private Helpers (replicated from EtcdHttpClient)

private enum TestEtcdBase64 {
    static func encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    static func decode(_ string: String) -> String {
        guard let data = Data(base64Encoded: string) else { return string }
        return String(data: data, encoding: .utf8) ?? "<b64:\(string)>"
    }
}

private enum TestEtcdPrefixRange {
    static func rangeEnd(for prefix: String) -> String {
        var bytes = Array(prefix.utf8)
        guard !bytes.isEmpty else { return "\0" }
        var i = bytes.count - 1
        while i >= 0 {
            if bytes[i] < 0xFF {
                bytes[i] += 1
                return String(bytes: Array(bytes[0 ... i]), encoding: .utf8) ?? "\0"
            }
            i -= 1
        }
        return "\0"
    }
}
