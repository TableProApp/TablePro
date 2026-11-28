//
//  TeamFingerprintCode.swift
//  TablePro
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// The in-person check of core ADR 0056, Pins: one device shows `TPF1:` and the fingerprint's 52 Base32 symbols as a
// QR code and the other reads it from a photo. The core compares the text; this only draws and reads the code.
internal enum TeamFingerprintCode {
    // Whole pixels per module, so the code stays sharp, inside the four-module light margin ISO/IEC 18004 asks for.
    static func image(for text: String, pixelsPerModule: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let margin = 4 * pixelsPerModule
        let scaled = code
            .transformed(by: CGAffineTransform(scaleX: pixelsPerModule, y: pixelsPerModule))
            .transformed(by: CGAffineTransform(translationX: margin, y: margin))
        let canvas = CGRect(x: 0, y: 0, width: scaled.extent.maxX + margin, height: scaled.extent.maxY + margin)
        let framed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
        return CIContext().createCGImage(framed, from: canvas.integral)
    }

    // Vision runs the detection synchronously, so it stays off the main actor.
    @concurrent
    nonisolated static func text(in image: CGImage) async -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.lazy.compactMap(\.payloadStringValue).first
    }
}
