//
//  CellImageRendererTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

private final class RecordingSvgRenderer: SvgImageRendering, @unchecked Sendable {
    private let png: Data?
    private(set) var calls = 0

    init(png: Data?) {
        self.png = png
    }

    func renderPng(from data: Data, maxPixelSize: Int) async -> Data? {
        calls += 1
        return png
    }
}

private func encodedPng(width: Int, height: Int) -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
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
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:]) ?? Data()
}

@MainActor
@Suite("CellImageRenderer", .serialized)
struct CellImageRendererTests {
    @Test("a raster value renders and reports the stored pixel size")
    func rasterRendersAtStoredSize() async {
        let data = encodedPng(width: 40, height: 24)
        let render = await CellImageRenderer.render(data, format: .raster("public.png"))
        guard case .rendered(_, let pixelSize) = render else {
            Issue.record("expected a rendered image, got \(render)")
            return
        }
        #expect(pixelSize == CGSize(width: 40, height: 24))
    }

    /// The preview is a thumbnail, so a large image never allocates its full decode.
    @Test("a raster value larger than the cap is drawn no larger than the cap")
    func rasterIsBoundedByTheCap() async {
        let data = encodedPng(width: 600, height: 300)
        let render = await CellImageRenderer.render(data, format: .raster("public.png"), maxPixelSize: 64)
        guard case .rendered(let image, let pixelSize) = render else {
            Issue.record("expected a rendered image, got \(render)")
            return
        }
        #expect(pixelSize == CGSize(width: 600, height: 300))
        /// `size`, not a representation's `pixelsWide`: an `NSImage` built from a `CGImage` carries
        /// an `NSCGImageSnapshotRep` that reports backing-store pixels, measured at 128x64 for this
        /// 64x32 thumbnail on a 2x display.
        #expect(image.size == CGSize(width: 64, height: 32))
    }

    @Test("bytes that do not decode fail rather than reporting an empty image")
    func undecodableRasterFails() async {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 16)
        let render = await CellImageRenderer.render(data, format: .raster("public.png"))
        #expect(render == .failed)
    }

    @Test("an empty value fails")
    func emptyFails() async {
        #expect(await CellImageRenderer.render(Data(), format: .svg) == .failed)
    }

    @Test("a value past the preview cap is reported rather than rendered")
    func oversizeIsReportedWithoutRendering() async {
        let renderer = RecordingSvgRenderer(png: encodedPng(width: 4, height: 4))
        let previous = CellImageRenderer.svgRenderer
        CellImageRenderer.svgRenderer = renderer
        defer { CellImageRenderer.svgRenderer = previous }

        let byteCount = CellImageSniffer.maxPreviewBytes + 1
        let render = await CellImageRenderer.render(Data(repeating: 0x20, count: byteCount), format: .svg)

        #expect(render == .tooLarge(byteCount: byteCount))
        #expect(renderer.calls == 0)
    }

    @Test("SVG goes through the out-of-process renderer")
    func svgUsesTheInjectedRenderer() async {
        let renderer = RecordingSvgRenderer(png: encodedPng(width: 12, height: 8))
        let previous = CellImageRenderer.svgRenderer
        CellImageRenderer.svgRenderer = renderer
        defer { CellImageRenderer.svgRenderer = previous }

        let render = await CellImageRenderer.render(Data("<svg/>".utf8), format: .svg)

        #expect(renderer.calls == 1)
        guard case .rendered(_, let pixelSize) = render else {
            Issue.record("expected a rendered image, got \(render)")
            return
        }
        #expect(pixelSize == nil)
    }

    /// A renderer that was killed on its deadline, or that crashed on a hostile document, answers
    /// with nothing. The viewer has to say so rather than show an empty pane.
    @Test("an SVG renderer that answers with nothing fails")
    func svgRendererFailureIsReported() async {
        let renderer = RecordingSvgRenderer(png: nil)
        let previous = CellImageRenderer.svgRenderer
        CellImageRenderer.svgRenderer = renderer
        defer { CellImageRenderer.svgRenderer = previous }

        #expect(await CellImageRenderer.render(Data("<svg/>".utf8), format: .svg) == .failed)
        #expect(renderer.calls == 1)
    }
}
