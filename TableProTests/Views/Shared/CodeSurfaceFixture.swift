//
//  CodeSurfaceFixture.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro

/// Hosts a view offscreen and adopts themes on the shared engine for the length of a body.
///
/// Synchronous and main-actor on purpose: nothing else on the main actor runs between adopting a
/// theme and restoring the original, so no suite running in parallel sees it.
@MainActor
internal enum CodeSurfaceFixture {
    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    static func host(_ view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Every text view in the window except a field editor, in subview order.
    static func textViews(in window: NSWindow) -> [NSTextView] {
        textViews(in: window.contentView)
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let textView = view as? NSTextView {
            return textView.isFieldEditor ? [] : [textView]
        }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    static func withBuiltInThemes<Result>(_ body: () throws -> Result) rethrows -> Result {
        try adopting(.builtIn, body)
    }

    /// Both themes of the pair set exactly `overrides`, so the result does not depend on appearance.
    static func withOverrides<Result>(_ overrides: [ThemeSlot: String], _ body: () throws -> Result) throws -> Result {
        var light = BuiltInThemes.light
        var dark = BuiltInThemes.dark
        light.id = "user.test.code-surface-light"
        dark.id = "user.test.code-surface-dark"
        for (slot, hex) in overrides {
            let color = try ThemeColor(validating: hex)
            light.overrides[slot] = color
            dark.overrides[slot] = color
        }
        return try adopting(ThemePair(light: light, dark: dark), body)
    }

    private static func adopting<Result>(_ pair: ThemePair, _ body: () throws -> Result) rethrows -> Result {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        engine.adopt(ThemeSelection(pair: pair, effectiveAppearance: .light))
        return try body()
    }

    /// A dynamic color resolved the way the hosted window draws it.
    static func hex(_ color: NSColor?) -> String? {
        guard let color else { return nil }
        var hex: String?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    /// Rendered at 1x, in the light scheme the adopted themes draw in.
    static func render(_ view: some View, size: NSSize) -> NSBitmapImageRep? {
        OffscreenRender.bitmap(of: view.frame(width: size.width, height: size.height), colorScheme: .light)
    }

    /// `ImageRenderer` leaves a `ScrollView`'s content out; caching the hosting view draws it.
    static func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// The rows below the top `fraction` of the bitmap, whatever its scale.
    static func rows(of bitmap: NSBitmapImageRep, below fraction: Double) -> Range<Int> {
        Int(Double(bitmap.pixelsHigh) * fraction) ..< bitmap.pixelsHigh
    }

    static func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    static func isMagenta(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5
            && color.redComponent > 0.75
            && color.greenComponent < 0.45
            && color.blueComponent > 0.75
    }

    static func magentaPixels(in bitmap: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var count = 0
        for y in rows.clamped(to: 0 ..< bitmap.pixelsHigh) {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = color(in: bitmap, x: x, y: y) else { continue }
                if isMagenta(color) { count += 1 }
            }
        }
        return count
    }
}
