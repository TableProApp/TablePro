//
//  RGBAColorNSColorTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

struct RGBAColorNSColorTests {
    @Test("The NSColor holds the same components in sRGB")
    func nsColorIsSRGB() {
        let color = RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 0.5).nsColor

        #expect(color.colorSpace == .sRGB)
        #expect(abs(color.redComponent - 1) < 0.0001)
        #expect(abs(color.greenComponent - 136.0 / 255) < 0.0001)
        #expect(abs(color.blueComponent) < 0.0001)
        #expect(abs(color.alphaComponent - 0.5) < 0.0001)
    }
}
