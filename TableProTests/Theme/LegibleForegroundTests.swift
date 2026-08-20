//
//  LegibleForegroundTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("Legible foreground")
@MainActor
struct LegibleForegroundTests {
    private static let appearances: [NSAppearance.Name] = [
        .aqua,
        .darkAqua,
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
    ]

    private func isBlack(on fill: Color) -> Bool {
        NSColor(Color.legibleForeground(on: fill)).relativeLuminance < 0.5
    }

    private func contrast(of fill: Color) -> CGFloat {
        let foreground = NSColor(Color.legibleForeground(on: fill)).relativeLuminance
        let background = NSColor(fill).relativeLuminance
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
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

    /// The palette is the one a tag or a connection can actually be given, resolved in every
    /// appearance the app can render in. `.gray` used to be the one colour left out, and it is the
    /// default a new tag gets.
    @Test("Every connection palette colour keeps a readable label in every appearance")
    func connectionPaletteStaysReadable() {
        for name in Self.appearances {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for color in ConnectionColor.allCases where !color.isDefault {
                    #expect(
                        contrast(of: color.color) >= 3.0,
                        "\(color.rawValue) does not reach 3:1 against its label in \(name.rawValue)"
                    )
                }
            }
        }
    }

    @Test("Semantic fills used behind derived labels stay readable")
    func semanticFillsStayReadable() {
        let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple, .pink, .brown]
        for fill in palette {
            #expect(contrast(of: fill) >= 3.0, "\(fill) does not reach 3:1 against its label")
        }
    }

    /// A fill the caller cannot see through is the only thing this function can reason about, so a
    /// transparent one has to be kept away from it by the call site rather than guessed at here.
    @Test("The uncoloured palette entry is transparent and is excluded by callers")
    func defaultPaletteEntryIsTransparent() {
        #expect(ConnectionColor.none.isDefault)
        #expect(NSColor(ConnectionColor.none.color).alphaComponent == 0)
    }

    @Test("Relative luminance is ordered")
    func luminanceOrdering() {
        #expect(NSColor.black.relativeLuminance < NSColor.white.relativeLuminance)
        #expect(NSColor.systemYellow.relativeLuminance > NSColor.systemBlue.relativeLuminance)
    }
}
