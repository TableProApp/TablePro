//
//  LegibleForegroundTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("Legible foreground")
struct LegibleForegroundTests {
    private func isBlack(on fill: Color) -> Bool {
        NSColor(Color.legibleForeground(on: fill)).relativeLuminance < 0.5
    }

    @Test("Dark fills take white text")
    func darkFillsTakeWhite() {
        #expect(isBlack(on: .black) == false)
        #expect(isBlack(on: .blue) == false)
        #expect(isBlack(on: .purple) == false)
    }

    @Test("Light fills take black text")
    func lightFillsTakeBlack() {
        #expect(isBlack(on: .white))
        #expect(isBlack(on: .yellow))
        #expect(isBlack(on: .mint))
    }

    @Test("Every tag palette colour keeps a readable label")
    func tagPaletteStaysReadable() {
        let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple, .pink, .brown]
        for fill in palette {
            let foreground = NSColor(Color.legibleForeground(on: fill)).relativeLuminance
            let background = NSColor(fill).relativeLuminance
            let lighter = max(foreground, background) + 0.05
            let darker = min(foreground, background) + 0.05
            #expect(lighter / darker >= 3.0, "\(fill) does not reach 3:1 against its label")
        }
    }

    @Test("Relative luminance is ordered")
    func luminanceOrdering() {
        #expect(NSColor.black.relativeLuminance < NSColor.white.relativeLuminance)
        #expect(NSColor.systemYellow.relativeLuminance > NSColor.systemBlue.relativeLuminance)
    }
}
