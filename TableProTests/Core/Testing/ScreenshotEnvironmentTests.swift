//
//  ScreenshotEnvironmentTests.swift
//  TableProTests
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

struct ScreenshotEnvironmentTests {
    @Test("Reads the size the marketing shots are cut to")
    func readsWidthAndHeight() throws {
        let size = try #require(ScreenshotEnvironment.size(from: "1512x861"))
        #expect(size.width == 1_512)
        #expect(size.height == 861)
    }

    @Test("Accepts an upper case separator")
    func acceptsUpperCaseSeparator() throws {
        let size = try #require(ScreenshotEnvironment.size(from: "1512X861"))
        #expect(size.width == 1_512)
    }

    /// Every one of these has to come back nil rather than a default. A default would open the
    /// window at some other size and the run would produce a file that looks fine on its own and
    /// is the wrong shape for the box the page reserves.
    @Test(
        "Refuses anything it cannot read",
        arguments: ["", "1512", "1512x", "x861", "1512x861x2", "widthxheight", "0x861", "1512x0", "-100x861"]
    )
    func refusesMalformedInput(_ raw: String) {
        #expect(ScreenshotEnvironment.size(from: raw) == nil)
    }

    @Test("The pinned frame is centred on the screen's visible frame")
    func pinnedFrameIsCentred() {
        let visible = NSRect(x: 0, y: 25, width: 2_560, height: 1_410)

        let frame = ScreenshotEnvironment.pinnedFrame(size: CGSize(width: 1_512, height: 861), in: visible)

        #expect(frame.size == CGSize(width: 1_512, height: 861))
        #expect(frame.midX == visible.midX)
        #expect(frame.midY == visible.midY)
    }
}
