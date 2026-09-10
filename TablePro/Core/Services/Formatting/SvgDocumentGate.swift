//
//  SvgDocumentGate.swift
//  TablePro
//
//  Shared by the app and the out-of-process renderer, so both refuse the same bytes.
//

import Foundation
import ImageIO

/// Whether bytes that read as a vector document really are one.
///
/// A prologue scan alone is not enough. DICOM carries a 128-byte free-form preamble, so a whole
/// DICOM fits inside an XML comment ahead of an `<svg>` root and reads as SVG to any scanner;
/// `NSImage(data:)` then declines it as a vector, falls through to `NSBitmapImageRep`, and runs
/// ImageIO's DICOM decoder over fully untrusted input. Measured: such a polyglot rasterizes at the
/// size its own DICOM tags declare.
///
/// A real vector document is invisible to ImageIO, so anything ImageIO claims is not one. Measured
/// against plain SVG and SVG behind a byte order mark, an XML declaration, a doctype and a comment:
/// `CGImageSourceGetType` is nil for every one of them.
internal enum SvgDocumentGate {
    static func isVectorDocument(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return true }
        return CGImageSourceGetType(source) == nil
    }
}
