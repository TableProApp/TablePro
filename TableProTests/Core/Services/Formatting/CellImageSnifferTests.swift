//
//  CellImageSnifferTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

/// Real encoder output rather than hand-typed prefixes, so a fixture cannot drift from what the
/// format actually looks like.
private enum ImageFixtures {
    static func encoded(as type: NSBitmapImageRep.FileType) -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 3,
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
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: type, properties: [:]) ?? Data()
    }

    static let svg = Data(
        #"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="3"><rect width="4" height="3"/></svg>"#.utf8
    )

    /// A DICOM whose 128-byte free-form preamble opens an XML comment, so the whole file hides ahead
    /// of an `<svg>` root and reads as SVG to a prologue scan.
    static func dicomBehindAnXmlComment() -> Data {
        func element(_ group: UInt16, _ number: UInt16, _ representation: String, _ value: Data) -> Data {
            var bytes = Data()
            withUnsafeBytes(of: group.littleEndian) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: number.littleEndian) { bytes.append(contentsOf: $0) }
            bytes.append(Data(representation.utf8))
            if representation == "OB" || representation == "OW" {
                bytes.append(contentsOf: [0, 0])
                withUnsafeBytes(of: UInt32(value.count).littleEndian) { bytes.append(contentsOf: $0) }
            } else {
                withUnsafeBytes(of: UInt16(value.count).littleEndian) { bytes.append(contentsOf: $0) }
            }
            bytes.append(value)
            return bytes
        }
        func short(_ value: UInt16) -> Data {
            var bytes = Data()
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
            return bytes
        }

        let syntax = element(0x0002, 0x0010, "UI", Data("1.2.840.10008.1.2.1\u{0}".utf8))
        var body = element(0x0002, 0x0000, "UL", {
            var bytes = Data()
            withUnsafeBytes(of: UInt32(syntax.count).littleEndian) { bytes.append(contentsOf: $0) }
            return bytes
        }())
        body.append(syntax)
        body.append(element(0x0008, 0x0060, "CS", Data("OT".utf8)))
        body.append(element(0x0009, 0x1001, "OB", Data("--><svg><rect/></svg>\u{0}".utf8)))
        body.append(element(0x0028, 0x0002, "US", short(1)))
        body.append(element(0x0028, 0x0004, "CS", Data("MONOCHROME2 ".utf8)))
        body.append(element(0x0028, 0x0010, "US", short(8)))
        body.append(element(0x0028, 0x0011, "US", short(8)))
        body.append(element(0x0028, 0x0100, "US", short(8)))
        body.append(element(0x0028, 0x0101, "US", short(8)))
        body.append(element(0x0028, 0x0102, "US", short(7)))
        body.append(element(0x0028, 0x0103, "US", short(0)))
        body.append(element(0x7FE0, 0x0010, "OW", Data(repeating: 0x80, count: 64)))

        var file = Data("<!--".utf8)
        file.append(Data(repeating: 0x20, count: 124))
        file.append(Data("DICM".utf8))
        file.append(body)
        return file
    }
}

@Suite("CellImageSniffer raster formats")
struct CellImageSnifferRasterTests {
    @Test(
        "an encoder's own output is recognised",
        arguments: [
            (NSBitmapImageRep.FileType.png, "public.png"),
            (NSBitmapImageRep.FileType.jpeg, "public.jpeg"),
            (NSBitmapImageRep.FileType.gif, "com.compuserve.gif"),
            (NSBitmapImageRep.FileType.tiff, "public.tiff"),
            (NSBitmapImageRep.FileType.bmp, "com.microsoft.bmp"),
        ]
    )
    func encodedFormatsAreRecognised(type: NSBitmapImageRep.FileType, identifier: String) {
        let data = ImageFixtures.encoded(as: type)
        #expect(!data.isEmpty)
        #expect(CellImageSniffer.format(of: data) == .raster(identifier))
    }

    @Test("a WebP header is recognised")
    func webpIsRecognised() {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(Data("WEBPVP8 ".utf8))
        data.append(Data(repeating: 0, count: 32))
        #expect(CellImageSniffer.format(of: data) == .raster("org.webmproject.webp"))
    }

    @Test("an ICO header is recognised")
    func icoIsRecognised() {
        var data = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])
        data.append(Data(repeating: 0, count: 64))
        #expect(CellImageSniffer.format(of: data) == .raster("com.microsoft.ico"))
    }

    /// `NSImage(data:)` opens all of these, which is exactly why it cannot be the test.
    @Test("PDF is not an image for this purpose")
    func pdfIsRejected() {
        let data = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x20, count: 64)
        #expect(CellImageSniffer.format(of: data) == nil)
    }

    @Test("empty data is not an image")
    func emptyIsRejected() {
        #expect(CellImageSniffer.format(of: Data()) == nil)
    }

    /// The cap belongs to the renderer, which says the value is too large. Refusing here instead
    /// would leave an oversize image reading as hex with nothing to explain why.
    @Test("a value past the preview cap is still recognised as an image")
    func oversizeIsStillAnImage() {
        var data = ImageFixtures.encoded(as: .png)
        data.append(Data(repeating: 0, count: CellImageSniffer.maxPreviewBytes))
        #expect(CellImageSniffer.format(of: data) == .raster("public.png"))
    }

    @Test("bytes handed over as one character each still classify")
    func latin1TextRecoversRasterBytes() throws {
        let png = ImageFixtures.encoded(as: .png)
        let asText = try #require(String(data: png, encoding: .isoLatin1))
        #expect(CellImageSniffer.format(ofText: asText) == .raster("public.png"))
    }
}

@Suite("CellImageSniffer SVG documents")
struct CellImageSnifferSvgTests {
    @Test(
        "a document whose root element is svg is recognised behind any prologue",
        arguments: [
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>"#,
            "<svg><rect/></svg>",
            "\n\n   <svg><rect/></svg>",
            "\u{FEFF}<svg><rect/></svg>",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg><rect/></svg>",
            "<!-- Generator: Adobe Illustrator -->\n<svg><rect/></svg>",
            "<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">\n<svg><rect/></svg>",
            "<?xml version=\"1.0\"?>\n<!-- c -->\n<!DOCTYPE svg>\n<svg><rect/></svg>",
            "<svg:svg xmlns:svg=\"http://www.w3.org/2000/svg\"><svg:rect/></svg:svg>",
            "<svg/>",
        ]
    )
    func svgDocumentsAreRecognised(markup: String) {
        #expect(CellImageSniffer.isSvgDocument(markup))
    }

    @Test(
        "anything whose root element is not svg is not an SVG document",
        arguments: [
            "",
            "hello world",
            "<html><body><svg><rect/></svg></body></html>",
            "<?xml version=\"1.0\"?><root><svg/></root>",
            "<svgx><rect/></svgx>",
            "<SVG><rect/></SVG>",
            "{\"svg\": true}",
            "<!-- <svg/> -->",
            "<?xml version=\"1.0\"?>",
        ]
    )
    func nonSvgIsRejected(markup: String) {
        #expect(!CellImageSniffer.isSvgDocument(markup))
    }

    @Test("a doctype with an internal subset does not swallow the root element")
    func internalSubsetIsSkipped() {
        let markup = "<!DOCTYPE svg [<!ENTITY a \"b\">]>\n<svg><rect/></svg>"
        #expect(CellImageSniffer.isSvgDocument(markup))
    }

    @Test("SVG bytes classify as SVG")
    func svgBytesClassify() {
        #expect(CellImageSniffer.format(of: ImageFixtures.svg) == .svg)
    }

    @Test("SVG markup handed over as text classifies as SVG")
    func svgTextClassifies() {
        #expect(CellImageSniffer.format(ofText: "<svg><rect/></svg>") == .svg)
    }

    /// A prologue scan alone reads this as SVG, because DICOM's 128-byte preamble can be an XML
    /// comment. Left there, the bytes would reach ImageIO's DICOM decoder through `NSImage`'s own
    /// fallback, which is the decoder the raster allowlist exists to exclude.
    @Test("a DICOM hidden behind an XML comment is not an image")
    func dicomPolyglotIsRefused() {
        let polyglot = ImageFixtures.dicomBehindAnXmlComment()
        #expect(CellImageSniffer.isSvgDocument(String(decoding: polyglot, as: UTF8.self)))
        #expect(!SvgDocumentGate.isVectorDocument(polyglot))
        #expect(CellImageSniffer.format(of: polyglot) == nil)
    }

    @Test("a real SVG passes the vector gate behind any prologue")
    func realSvgPassesTheGate() {
        #expect(SvgDocumentGate.isVectorDocument(ImageFixtures.svg))
        #expect(SvgDocumentGate.isVectorDocument(Data("<svg><rect/></svg>".utf8)))
    }
}
