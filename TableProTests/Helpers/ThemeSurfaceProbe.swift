//
//  ThemeSurfaceProbe.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// A synchronous body runs whole on the main actor, so no other test sees the adopted pair.
@MainActor
internal enum ThemeSurfaceProbe {
    internal static let windowHex = "#282A36"
    internal static let editorHex = "#1B3A2C"
    internal static let gridHex = "#3A1E4F"

    internal static func darkTheme(_ overrides: [ThemeSlot: String]) throws -> ThemeDefinition {
        var theme = BuiltInThemes.dark
        theme.id = "user.test.surface-\(overrides.keys.map(\.rawValue).sorted().joined(separator: "+"))"
        for (slot, hex) in overrides {
            theme.overrides[slot] = try ThemeColor(validating: hex)
        }
        return theme
    }

    internal static func adopting(dark: ThemeDefinition, _ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        adopt(dark: dark)
        try body()
    }

    /// Only inside `adopting`, which puts the engine's own pair back.
    internal static func adopt(dark: ThemeDefinition) {
        ThemeEngine.shared.adopt(ThemeSelection(pair: ThemePair(light: BuiltInThemes.light, dark: dark), effectiveAppearance: .dark))
    }

    /// `at` is a fraction of the rendered size, measured from the top leading corner.
    internal static func color(of view: some View, at point: CGPoint) throws -> NSColor {
        let rep = try #require(OffscreenRender.bitmap(of: view, colorScheme: .dark))
        let x = min(rep.pixelsWide - 1, Int(CGFloat(rep.pixelsWide) * point.x))
        let y = min(rep.pixelsHigh - 1, Int(CGFloat(rep.pixelsHigh) * point.y))
        let color = try #require(rep.colorAt(x: x, y: y))
        return try #require(color.usingColorSpace(.sRGB))
    }

    /// Rendered the same way as the surface, so the renderer's color management cancels out.
    internal static func filled(_ color: NSColor) throws -> NSColor {
        try Self.color(of: Color(nsColor: color).frame(width: 24, height: 24), at: CGPoint(x: 0.5, y: 0.5))
    }

    internal static func filled(hex: String) throws -> NSColor {
        try filled(HexColor.color(hex))
    }

    internal static func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= 0.02
            && abs(lhs.greenComponent - rhs.greenComponent) <= 0.02
            && abs(lhs.blueComponent - rhs.blueComponent) <= 0.02
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= 0.02
    }
}
