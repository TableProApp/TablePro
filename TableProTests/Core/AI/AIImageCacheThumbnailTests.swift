//
//  AIImageCacheThumbnailTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

struct AIImageCacheThumbnailTests {
    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
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
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("A thumbnail is scaled down to the size asked for, and kept")
    func thumbnailIsScaledDownAndCached() throws {
        let cache = AIImageCache.shared
        let filename = cache.store(data: try pngData(width: 2_000, height: 1_000), mediaType: "image/png")
        defer { cache.delete(filename: filename) }

        #expect(cache.cachedThumbnail(filename: filename, maxPixelSize: 192) == nil)
        let thumbnail = try #require(cache.thumbnail(filename: filename, maxPixelSize: 192))
        let image = try #require(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(image.width, image.height) == 192)
        #expect(cache.cachedThumbnail(filename: filename, maxPixelSize: 192) != nil)
    }

    @Test("A filename outside the cache gives no thumbnail")
    func traversalIsRejected() {
        #expect(AIImageCache.shared.thumbnail(filename: "../secret.png", maxPixelSize: 96) == nil)
    }
}
