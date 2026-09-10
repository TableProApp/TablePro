//
//  CellValueContentDetectorTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
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

@Suite("CellValueContentDetector image content")
struct CellValueContentDetectorImageTests {
    private func encodedPng() -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    @Test("SVG markup in a text value is detected")
    func svgTextDetected() {
        #expect(CellValueContentDetector.detect("<svg><rect/></svg>") == .image(.svg))
    }

    @Test("SVG bytes are detected")
    func svgBytesDetected() {
        let value = PluginCellValue.bytes(Data("<svg><rect/></svg>".utf8))
        #expect(CellValueContentDetector.detect(value) == .image(.svg))
    }

    @Test("PNG bytes are detected")
    func pngBytesDetected() {
        #expect(CellValueContentDetector.detect(.bytes(encodedPng())) == .image(.raster("public.png")))
    }

    /// Several bundled drivers hand binary content over as a string, one character per stored byte.
    @Test("PNG bytes handed over as text are detected")
    func pngTextDetected() throws {
        let asText = try #require(String(data: encodedPng(), encoding: .isoLatin1))
        #expect(CellValueContentDetector.detect(.text(asText)) == .image(.raster("public.png")))
    }

    @Test("a NULL value is plain")
    func nullIsPlain() {
        #expect(CellValueContentDetector.detect(PluginCellValue.null) == .plain)
    }

    @Test("JSON still wins over image detection")
    func jsonStillWins() {
        #expect(CellValueContentDetector.detect(#"{"a":1}"#) == .json)
    }

    @Test("PHP serialized still wins over image detection")
    func phpStillWins() {
        #expect(CellValueContentDetector.detect("a:0:{}") == .phpSerialized)
    }

    @Test("plain markup that is not an SVG document stays plain")
    func htmlStaysPlain() {
        #expect(CellValueContentDetector.detect("<html><body><svg/></body></html>") == .plain)
    }
}
