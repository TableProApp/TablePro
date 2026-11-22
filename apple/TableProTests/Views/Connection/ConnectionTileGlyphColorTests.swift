//
//  ConnectionTileGlyphColorTests.swift
//  TableProTests
//

import AppKit
import Foundation
import Testing

@testable import TablePro

// Brand hues are picked for a white page: on the dark tile PostgreSQL's elephant nearly vanished.
@MainActor
struct ConnectionTileGlyphColorTests {
    private static let postgresBlue = NSColor(srgbRed: 0x33 / 255, green: 0x67 / 255, blue: 0x91 / 255, alpha: 1)
    private static let orange = NSColor(srgbRed: 0xF2 / 255, green: 0x91 / 255, blue: 0x11 / 255, alpha: 1)
    private static let tolerance: CGFloat = 0.01

    private struct Resolved {
        let glyph: NSColor
        let tileLuminance: CGFloat

        var contrast: CGFloat {
            ConnectionTileMetrics.contrast(glyph.relativeLuminance, tileLuminance)
        }
    }

    private func resolve(_ brand: NSColor, in name: NSAppearance.Name) throws -> Resolved {
        let appearance = try #require(NSAppearance(named: name))
        let color = ConnectionTileMetrics.glyphColor(brand: brand)
        var glyph: NSColor?
        var tile: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            glyph = color.usingColorSpace(.sRGB)
            tile = ConnectionTileMetrics.tileLuminance()
        }
        return Resolved(glyph: try #require(glyph), tileLuminance: tile)
    }

    private func hue(of color: NSColor) -> CGFloat {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return hue
    }

    @Test("PostgreSQL's blue fails on the dark tile as drawn, and the lifted glyph clears 3:1")
    func postgresBlueIsLiftedInDarkMode() throws {
        let resolved = try resolve(Self.postgresBlue, in: .darkAqua)
        let raw = ConnectionTileMetrics.contrast(Self.postgresBlue.relativeLuminance, resolved.tileLuminance)

        #expect(raw < ConnectionTileMetrics.minimumGlyphContrast)
        #expect(resolved.contrast >= ConnectionTileMetrics.minimumGlyphContrast - Self.tolerance)
        #expect(abs(hue(of: resolved.glyph) - hue(of: Self.postgresBlue)) < Self.tolerance)
    }

    @Test("Light Mode draws the brand colour as it is")
    func lightModeKeepsTheBrand() throws {
        let resolved = try resolve(Self.postgresBlue, in: .aqua)
        #expect(abs(resolved.glyph.redComponent - Self.postgresBlue.redComponent) < Self.tolerance)
        #expect(abs(resolved.glyph.greenComponent - Self.postgresBlue.greenComponent) < Self.tolerance)
        #expect(abs(resolved.glyph.blueComponent - Self.postgresBlue.blueComponent) < Self.tolerance)
    }

    @Test("A brand that already clears the dark tile is left alone")
    func legibleBrandIsUntouched() throws {
        let resolved = try resolve(Self.orange, in: .darkAqua)
        #expect(abs(resolved.glyph.redComponent - Self.orange.redComponent) < Self.tolerance)
        #expect(abs(resolved.glyph.greenComponent - Self.orange.greenComponent) < Self.tolerance)
        #expect(abs(resolved.glyph.blueComponent - Self.orange.blueComponent) < Self.tolerance)
    }

    @Test("A hue too dark at full brightness gives up saturation and still clears 3:1")
    func pureBlueClearsTheFloor() throws {
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let resolved = try resolve(blue, in: .darkAqua)
        #expect(resolved.contrast >= ConnectionTileMetrics.minimumGlyphContrast - Self.tolerance)
    }
}
