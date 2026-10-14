//
//  ThemeTestFixture.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

/// Synchronous and main-actor, so nothing else on the main actor runs between an adopt and its restore.
@MainActor
internal enum ThemeTestFixture {}

// MARK: - Engine

internal extension ThemeTestFixture {
    static func preservingEngine<Result>(_ body: () throws -> Result) rethrows -> Result {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        return try body()
    }

    /// Only inside `preservingEngine` or `adopting`, which put the incoming pair back.
    static func adopt(_ pair: ThemePair, appearance: ThemeAppearance) {
        ThemeEngine.shared.adopt(ThemeSelection(pair: pair, effectiveAppearance: appearance))
    }

    static func adopt(_ overrides: [ThemeSlot: String], appearance: ThemeAppearance) throws {
        adopt(try pair(overrides, on: appearance), appearance: appearance)
    }

    static func adopting<Result>(
        _ pair: ThemePair,
        appearance: ThemeAppearance,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try preservingEngine {
            adopt(pair, appearance: appearance)
            return try body()
        }
    }

    static func adopting<Result>(
        _ overrides: [ThemeSlot: String],
        appearance: ThemeAppearance,
        _ body: () throws -> Result
    ) throws -> Result {
        try adopting(try pair(overrides, on: appearance), appearance: appearance, body)
    }

    /// Keeps the incoming appearance; a surface that still reads any slot then draws magenta.
    static func withEverySlotOverridden<Result>(_ body: () throws -> Result) throws -> Result {
        let everySlot = Dictionary(uniqueKeysWithValues: ThemeSlot.allCases.map { ($0, "#FF00FF") })
        return try adopting(try pair(everySlot), appearance: ThemeEngine.shared.effectiveAppearance, body)
    }
}

// MARK: - Themes

internal extension ThemeTestFixture {
    static let windowHex = "#282A36"
    static let editorHex = "#1B3A2C"
    static let gridHex = "#3A1E4F"

    /// A theme that keeps a default id ignores its syntax overrides, so an overridden one takes a test id.
    static func theme(_ appearance: ThemeAppearance, _ overrides: [ThemeSlot: String]) throws -> ThemeDefinition {
        var theme = BuiltInThemes.default(for: appearance)
        guard !overrides.isEmpty else { return theme }
        theme.id = "user.test.\(appearance.rawValue)-\(overrides.keys.map(\.rawValue).sorted().joined(separator: "+"))"
        for (slot, hex) in overrides {
            theme.overrides[slot] = try ThemeColor(validating: hex)
        }
        return theme
    }

    /// The built-in pair with `overrides` on one appearance's theme; an empty set is the built-in pair.
    static func pair(_ overrides: [ThemeSlot: String], on appearance: ThemeAppearance) throws -> ThemePair {
        let themed = try theme(appearance, overrides)
        switch appearance {
        case .light: return ThemePair(light: themed, dark: BuiltInThemes.dark)
        case .dark: return ThemePair(light: BuiltInThemes.light, dark: themed)
        }
    }

    /// Both themes set `overrides`, so a surface draws them in either appearance.
    static func pair(_ overrides: [ThemeSlot: String]) throws -> ThemePair {
        ThemePair(light: try theme(.light, overrides), dark: try theme(.dark, overrides))
    }
}

// MARK: - Rendering

internal extension ThemeTestFixture {
    /// Not `ImageRenderer.cgImage`: it reuses an uncleared buffer, so a view that draws nothing reads back the last render.
    static func render(_ view: some View, colorScheme: ColorScheme, scale: CGFloat = 1) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, colorScheme))
        var image: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            image = context.makeImage()
        }
        return image.map(NSBitmapImageRep.init(cgImage:))
    }

    static func bitmap(of view: some View, colorScheme: ColorScheme) throws -> NSBitmapImageRep {
        try #require(render(view, colorScheme: colorScheme))
    }

    static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// `point` is a fraction of the rendered size, measured from the top leading corner.
    static func color(of view: some View, at point: CGPoint, colorScheme: ColorScheme) throws -> NSColor {
        let rep = try bitmap(of: view, colorScheme: colorScheme)
        let x = min(rep.pixelsWide - 1, Int(CGFloat(rep.pixelsWide) * point.x))
        let y = min(rep.pixelsHigh - 1, Int(CGFloat(rep.pixelsHigh) * point.y))
        return try #require(pixel(rep, x: x, y: y))
    }

    /// Rendered the same way as the surface, so the renderer's color management cancels out.
    static func filled(_ style: some ShapeStyle, colorScheme: ColorScheme) throws -> NSColor {
        try color(of: Rectangle().fill(style).frame(width: 24, height: 24), at: CGPoint(x: 0.5, y: 0.5), colorScheme: colorScheme)
    }

    static func filled(_ color: NSColor, colorScheme: ColorScheme) throws -> NSColor {
        try filled(Color(nsColor: color), colorScheme: colorScheme)
    }

    static func filled(hex: String, colorScheme: ColorScheme) throws -> NSColor {
        try filled(HexColor.color(hex), colorScheme: colorScheme)
    }

    static func matches(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    static func count(in bitmap: NSBitmapImageRep, rows: Range<Int>? = nil, where predicate: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in (rows ?? 0 ..< bitmap.pixelsHigh).clamped(to: 0 ..< bitmap.pixelsHigh) {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = pixel(bitmap, x: x, y: y) else { continue }
                if predicate(color) { count += 1 }
            }
        }
        return count
    }

    static func isMagenta(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5
            && color.redComponent > 0.75
            && color.greenComponent < 0.45
            && color.blueComponent > 0.75
    }

    static func sameBytes(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Bool {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh,
              let left = lhs.representation(using: .png, properties: [:]),
              let right = rhs.representation(using: .png, properties: [:]) else { return false }
        return left == right
    }
}

// MARK: - Hosting

internal extension ThemeTestFixture {
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

    /// In a borderless Dark Aqua window, never ordered front and never closed.
    static func hostingView(_ view: some View, size: NSSize) -> NSHostingView<AnyView> {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        window.contentView = host
        return host
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

    /// `ImageRenderer` leaves a `ScrollView`'s content out; caching the hosting view draws it.
    static func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}

// MARK: - Colors

internal extension ThemeTestFixture {
    /// A dynamic color resolved the way a view in that appearance draws it.
    static func hex(_ color: NSColor?, in name: NSAppearance.Name = .aqua) -> String? {
        guard let color, let appearance = NSAppearance(named: name) else { return nil }
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let nsColor = NSColor(cgColor: color) else { return nil }
        return HexColor.string(from: nsColor)
    }

    static func baked(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        resolved(in: appearance) { color.cgColor }
    }

    /// `withAlphaComponent` outside the appearance freezes a system color in the test host's appearance.
    static func resolved(in appearance: NSAppearance, _ make: () -> CGColor) -> CGColor {
        var result: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            result = make()
        }
        return result ?? make()
    }
}
