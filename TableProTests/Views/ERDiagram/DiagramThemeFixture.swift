//
//  DiagramThemeFixture.swift
//  TableProTests
//
//  Puts a known pair in front of the diagrams and the chart. Callers are synchronous and
//  `@MainActor`, so nothing else on the main actor runs between an adopt and its restore.
//

import AppKit
import SwiftUI
@testable import TablePro

@MainActor
enum DiagramThemeFixture {
    static func preservingEngine(_ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        try body()
    }

    /// An empty set adopts the built-in pair.
    static func adopt(_ overrides: [ThemeSlot: String], appearance: ThemeAppearance = .light) throws {
        var light = BuiltInThemes.light
        var dark = BuiltInThemes.dark
        if !overrides.isEmpty {
            var theme = BuiltInThemes.default(for: appearance)
            theme.id = "user.test.diagram-\(appearance.rawValue)"
            for (slot, hex) in overrides {
                theme.overrides[slot] = try ThemeColor(validating: hex)
            }
            switch appearance {
            case .light: light = theme
            case .dark: dark = theme
            }
        }
        ThemeEngine.shared.adopt(ThemeSelection(
            pair: ThemePair(light: light, dark: dark),
            effectiveAppearance: appearance
        ))
    }

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let nsColor = NSColor(cgColor: color) else { return nil }
        return HexColor.string(from: nsColor)
    }

    static func baked(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        resolved(in: appearance) { color.cgColor }
    }

    /// For an expression that has to run inside the appearance, the way a view's `draw` runs it:
    /// `withAlphaComponent` outside it freezes a system color in the test host's appearance.
    static func resolved(in appearance: NSAppearance, _ make: () -> CGColor) -> CGColor {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            result = make()
        }
        return result ?? make()
    }

    static func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    /// `ImageRenderer` takes its scheme from the environment, never from the current appearance.
    static func render(_ content: some View, colorScheme: ColorScheme) -> NSBitmapImageRep? {
        OffscreenRender.bitmap(of: content, colorScheme: colorScheme)
    }

    static func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// A fill run through the same renderer, so color space conversions cancel out.
    static func reference(_ style: some ShapeStyle, colorScheme: ColorScheme) -> NSColor? {
        guard let rep = render(Rectangle().fill(style).frame(width: 8, height: 8), colorScheme: colorScheme) else {
            return nil
        }
        return pixel(rep, x: 4, y: 4)
    }

    static func count(in rep: NSBitmapImageRep, matching color: NSColor, tolerance: CGFloat = 0.02) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = pixel(rep, x: x, y: y) else { continue }
                if matches(pixel, color, tolerance: tolerance) { count += 1 }
            }
        }
        return count
    }
}
