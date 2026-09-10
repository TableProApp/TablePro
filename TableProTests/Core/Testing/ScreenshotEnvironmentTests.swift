//
//  ScreenshotEnvironmentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ScreenshotEnvironment frame parsing")
struct ScreenshotEnvironmentTests {
    @Test("Reads the size the marketing shots are cut to")
    func readsWidthAndHeight() throws {
        let size = try #require(ScreenshotEnvironment.size(from: "1512x861"))
        #expect(size.width == 1512)
        #expect(size.height == 861)
    }

    @Test("Accepts an upper case separator")
    func acceptsUpperCaseSeparator() throws {
        let size = try #require(ScreenshotEnvironment.size(from: "1512X861"))
        #expect(size.width == 1512)
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
}
