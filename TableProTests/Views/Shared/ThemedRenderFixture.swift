//
//  ThemedRenderFixture.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// Adopts a theme pair on the shared engine for the length of `body` and renders SwiftUI offscreen.
/// Synchronous and main-actor, like `PaneThemeFixture`, so no suite running in parallel sees the pair.
@MainActor
internal enum ThemedRenderFixture {
    static func theme(_ appearance: ThemeAppearance, _ overrides: [ThemeSlot: String]) throws -> ThemeDefinition {
        var colors: [ThemeSlot: ThemeColor] = [:]
        for (slot, value) in overrides {
            colors[slot] = try ThemeColor(validating: value)
        }
        return ThemeDefinition(
            id: "user.test.render-\(appearance.rawValue)",
            name: "Render Test",
            author: "",
            appearance: appearance,
            overrides: colors
        )
    }

    static func pair(_ overrides: [ThemeSlot: String]) throws -> ThemePair {
        ThemePair(light: try theme(.light, overrides), dark: try theme(.dark, overrides))
    }

    static func adopting(
        _ pair: ThemePair,
        appearance: ThemeAppearance = .dark,
        _ body: (ThemeEngine) throws -> Void
    ) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: pair, effectiveAppearance: appearance))
        try body(engine)
    }

    static func bitmap(of view: some View, colorScheme: ColorScheme = .dark) throws -> NSBitmapImageRep {
        try #require(OffscreenRender.bitmap(of: view, colorScheme: colorScheme))
    }

    static func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        let color = try #require(bitmap.colorAt(x: x, y: y))
        return try #require(color.usingColorSpace(.sRGB))
    }

    /// A plain fill rendered the same way, so the renderer's own color management cancels out.
    static func filled(_ color: NSColor, colorScheme: ColorScheme = .dark) throws -> NSColor {
        let swatch = try bitmap(of: Color(nsColor: color).frame(width: 24, height: 24), colorScheme: colorScheme)
        return try Self.color(in: swatch, x: 12, y: 12)
    }

    static func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    static func pixelCount(in bitmap: NSBitmapImageRep, where predicate: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if predicate(color) { count += 1 }
            }
        }
        return count
    }

    static func isMagenta(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.3 && color.redComponent > 0.7 && color.blueComponent > 0.7 && color.greenComponent < 0.5
    }

    static func sameBytes(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Bool {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh,
              let left = lhs.representation(using: .png, properties: [:]),
              let right = rhs.representation(using: .png, properties: [:]) else { return false }
        return left == right
    }
}
