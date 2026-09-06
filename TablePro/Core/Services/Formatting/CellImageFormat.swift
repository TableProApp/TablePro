//
//  CellImageFormat.swift
//  TablePro
//
//  Identifies a cell value as an image from its content, without decoding it.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

internal enum CellImageFormat: Equatable, Sendable {
    case svg
    case raster(String)

    var displayName: String {
        switch self {
        case .svg:
            return "SVG"
        case .raster(let identifier):
            return UTType(identifier)?.localizedDescription ?? identifier
        }
    }
}

/// A cell's bytes together with what they turned out to be, so a view never has to sniff again.
internal struct CellImageValue: Equatable, Sendable {
    let data: Data
    let format: CellImageFormat
}

/// Answers "is this value an image, and which kind" from a header or an XML prologue.
///
/// `NSImage(data:)` is not the test, however tempting: `NSImage.imageTypes` also covers PDF, DICOM,
/// Photoshop and every camera RAW format, so trusting it would open a PDF as the image in a cell.
/// The raster answer therefore comes from `CGImageSourceGetType` against an explicit allowlist,
/// which reads a header and never decodes.
internal enum CellImageSniffer {
    /// Past this `CellImageRenderer` reports the value as too large rather than drawing it. The
    /// sniffer itself is size-agnostic, so an oversize image is still recognised as one and says so
    /// rather than silently reading as hex.
    static let maxPreviewBytes = 16 * 1_024 * 1_024

    /// An XML prologue is a declaration, comments and a doctype. A root element that has not
    /// started by here is not one this app is going to render.
    private static let maxPrologueScan = 8_192

    /// Every format in the allowlist declares itself in its first few bytes, HEIC's `ftyp` box
    /// included, so the header read never copies more than this. The row inspector resolves an
    /// editor for every field of the selected row, and copying each whole value to look at its
    /// first sixteen bytes is what that would otherwise cost.
    private static let maxHeaderBytes = 1_024

    private static let rasterTypes: Set<String> = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        "public.jpeg-2000",
        UTType.gif.identifier,
        UTType.tiff.identifier,
        UTType.bmp.identifier,
        UTType.ico.identifier,
        UTType.webP.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        "public.avif",
    ]

    static func format(of data: Data) -> CellImageFormat? {
        guard !data.isEmpty else { return nil }
        if let identifier = rasterIdentifier(of: data.prefix(maxHeaderBytes)) {
            return .raster(identifier)
        }
        /// ISO Latin-1 rather than UTF-8, because a prefix can cut a multi-byte sequence and the
        /// failable UTF-8 decode then answers nil for a document that is plainly SVG. Every token a
        /// prologue is made of is ASCII, which both encodings agree on, so the scan below cannot
        /// tell the difference.
        guard let text = String(bytes: data.prefix(maxPrologueScan), encoding: .isoLatin1) else { return nil }
        return isSvgDocument(text) && SvgDocumentGate.isVectorDocument(data) ? .svg : nil
    }

    /// The same question for a driver that hands its values over as text. SVG is answered from the
    /// characters, and a raster header from the bytes those characters stand for.
    static func format(ofText text: String) -> CellImageFormat? {
        guard !text.isEmpty else { return nil }
        if isSvgDocument(text) {
            return SvgDocumentGate.isVectorDocument(text.storedBytes) ? .svg : nil
        }
        let header = (text as NSString).substring(to: min((text as NSString).length, maxHeaderBytes))
        guard let identifier = rasterIdentifier(of: header.storedBytes) else { return nil }
        return .raster(identifier)
    }

    /// Every allow-listed format declares itself inside twelve bytes, so a value that cannot be one
    /// is rejected before ImageIO is asked. That matters because the row inspector resolves an editor
    /// for every field of the selected row and almost none of them are images: measured, the header
    /// read alone is 5.5 microseconds a field, and this prefilter answers in 348 nanoseconds.
    private static func couldBeRaster(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 2 else { return false }

        func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }

        if matches([0x89, 0x50, 0x4E, 0x47]) { return true }
        if matches([0xFF, 0xD8, 0xFF]) { return true }
        if matches([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) { return true }
        if matches(Array("GIF8".utf8)) { return true }
        if matches([0x49, 0x49, 0x2A, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if matches(Array("BM".utf8)) { return true }
        if matches([0x00, 0x00, 0x01, 0x00]) || matches([0x00, 0x00, 0x02, 0x00]) { return true }
        if matches(Array("RIFF".utf8)) { return true }
        if matches(Array("ftyp".utf8), at: 4) { return true }
        return false
    }

    private static func rasterIdentifier(of data: Data) -> String? {
        guard couldBeRaster(data) else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source) as String?
        else { return nil }
        return rasterTypes.contains(identifier) ? identifier : nil
    }

    /// SVG has no magic number, so the document has to say so itself: an optional byte order mark,
    /// then any run of whitespace, XML declarations, comments and a doctype, then a root element
    /// named `svg`. Requiring the namespace would be stricter than the renderer, which draws a
    /// namespace-less `<svg>` happily, so the element name is the whole test.
    static func isSvgDocument(_ text: String) -> Bool {
        let source = text as NSString
        let limit = min(source.length, maxPrologueScan)
        var index = 0
        if limit > 0, source.character(at: 0) == 0xFEFF { index = 1 }

        while index < limit {
            if isXmlWhitespace(source.character(at: index)) {
                index += 1
                continue
            }
            guard source.character(at: index) == unit("<"), index + 1 < limit else { return false }
            let second = source.character(at: index + 1)
            if second == unit("?") {
                guard let next = endOfProcessingInstruction(source, from: index + 2, limit: limit) else { return false }
                index = next
            } else if second == unit("!") {
                guard let next = endOfDeclaration(source, from: index + 2, limit: limit) else { return false }
                index = next
            } else {
                return startsSvgElement(source, at: index + 1, limit: limit)
            }
        }
        return false
    }

    private static func unit(_ character: Unicode.Scalar) -> unichar {
        unichar(character.value)
    }

    private static func isXmlWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    private static func endOfProcessingInstruction(_ source: NSString, from start: Int, limit: Int) -> Int? {
        var index = start
        while index + 1 < limit {
            if source.character(at: index) == unit("?"), source.character(at: index + 1) == unit(">") {
                return index + 2
            }
            index += 1
        }
        return nil
    }

    /// Both shapes that open `<!`: a comment, and a doctype whose internal subset may itself carry
    /// `>` inside brackets.
    private static func endOfDeclaration(_ source: NSString, from start: Int, limit: Int) -> Int? {
        if start + 1 < limit,
           source.character(at: start) == unit("-"),
           source.character(at: start + 1) == unit("-") {
            return endOfComment(source, from: start + 2, limit: limit)
        }

        var index = start
        var bracketDepth = 0
        while index < limit {
            let character = source.character(at: index)
            if character == unit("[") {
                bracketDepth += 1
            } else if character == unit("]") {
                bracketDepth -= 1
            } else if character == unit(">"), bracketDepth <= 0 {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private static func endOfComment(_ source: NSString, from start: Int, limit: Int) -> Int? {
        var index = start
        while index + 2 < limit {
            if source.character(at: index) == unit("-"),
               source.character(at: index + 1) == unit("-"),
               source.character(at: index + 2) == unit(">") {
                return index + 3
            }
            index += 1
        }
        return nil
    }

    /// XML is case sensitive and the element is `svg`, optionally behind a namespace prefix.
    private static func startsSvgElement(_ source: NSString, at start: Int, limit: Int) -> Bool {
        var index = start
        var name = ""
        while index < limit {
            let character = source.character(at: index)
            if isXmlWhitespace(character) || character == unit(">") || character == unit("/") { break }
            guard let scalar = Unicode.Scalar(character) else { return false }
            name.unicodeScalars.append(scalar)
            if name.count > 64 { return false }
            index += 1
        }
        guard !name.isEmpty else { return false }
        return name.split(separator: ":", omittingEmptySubsequences: false).last == "svg"
    }
}
