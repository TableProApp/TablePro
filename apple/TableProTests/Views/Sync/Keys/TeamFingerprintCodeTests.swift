//
//  TeamFingerprintCodeTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

struct TeamFingerprintCodeTests {
    // `TPF1:` and 52 Crockford Base32 symbols whose last 4 bits are zero (core ADR 0056, Pins).
    private static let code = "TPF1:7ZQ3M0V9K2H8T4XWB6N1C5RYD7JA3G9PFE2S8KMV0QHT4WXA9BC0"

    @Test("The QR code drawn for a fingerprint reads back as the same text")
    func roundTrips() async throws {
        let image = try #require(TeamFingerprintCode.image(for: Self.code))

        #expect(image.width == image.height)
        #expect(await TeamFingerprintCode.text(in: image) == Self.code)
    }

    @Test("A picture with no code reads as nothing")
    func blankPictureReadsNothing() async throws {
        let context = try #require(CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let blank = try #require(context.makeImage())

        #expect(await TeamFingerprintCode.text(in: blank) == nil)
    }
}
