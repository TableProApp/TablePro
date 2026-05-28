//
//  CellValueContentDetectorTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("CellValueContentDetector")
struct CellValueContentDetectorTests {
    @Test("empty string is plain")
    func emptyIsPlain() {
        #expect(CellValueContentDetector.detect("") == .plain)
    }

    @Test("JSON object is detected")
    func jsonObjectDetected() {
        #expect(CellValueContentDetector.detect(#"{"a":1}"#) == .json)
    }

    @Test("JSON array is detected")
    func jsonArrayDetected() {
        #expect(CellValueContentDetector.detect("[1,2,3]") == .json)
    }

    @Test("Invalid JSON falls through to plain")
    func invalidJsonIsPlain() {
        #expect(CellValueContentDetector.detect("{not json") == .plain)
    }

    @Test("PHP null is detected")
    func phpNullDetected() {
        #expect(CellValueContentDetector.detect("N;") == .phpSerialized)
    }

    @Test("PHP array is detected")
    func phpArrayDetected() {
        #expect(CellValueContentDetector.detect("a:0:{}") == .phpSerialized)
    }

    @Test("PHP object is detected")
    func phpObjectDetected() {
        #expect(CellValueContentDetector.detect("O:4:\"User\":0:{}") == .phpSerialized)
    }

    @Test("plain text starting with s: stays plain when not PHP-shaped")
    func plainSPrefix() {
        #expect(CellValueContentDetector.detect("some text") == .plain)
    }

    @Test("plain text starting with a stays plain")
    func plainAPrefix() {
        #expect(CellValueContentDetector.detect("a quick brown fox") == .plain)
    }

    @Test("plain JSON-looking text without object braces is plain")
    func barePrimitiveIsPlain() {
        #expect(CellValueContentDetector.detect("hello world") == .plain)
        #expect(CellValueContentDetector.detect("123") == .plain)
    }

    @Test("English text starting with any PHP token character stays plain")
    func englishStartingWithPhpTokenChars() {
        #expect(CellValueContentDetector.detect("because of this") == .plain)
        #expect(CellValueContentDetector.detect("it works correctly") == .plain)
        #expect(CellValueContentDetector.detect("data not loaded") == .plain)
        #expect(CellValueContentDetector.detect("Some upper-case text") == .plain)
        #expect(CellValueContentDetector.detect("Other text starting with O") == .plain)
        #expect(CellValueContentDetector.detect("Custom message here") == .plain)
        #expect(CellValueContentDetector.detect("offset = 0") == .plain)
        #expect(CellValueContentDetector.detect("running test") == .plain)
        #expect(CellValueContentDetector.detect("Remote URL") == .plain)
        #expect(CellValueContentDetector.detect("No data found") == .plain)
    }

    @Test("malformed but PHP-prefix shaped text is detected as PHP (parser rejects later)")
    func malformedPhpStillDetected() {
        #expect(CellValueContentDetector.detect("s:99:\"short\";") == .phpSerialized)
    }

    @Test("value above 5 MB is plain regardless of shape")
    func sizeCapEnforced() {
        let huge = String(repeating: "a", count: 5_000_001)
        #expect(CellValueContentDetector.detect(huge) == .plain)
    }
}
