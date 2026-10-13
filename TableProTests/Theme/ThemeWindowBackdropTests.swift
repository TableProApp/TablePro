//
//  ThemeWindowBackdropTests.swift
//  TableProTests
//
//  Any window color other than a system one replaces the window's own content-background material,
//  so the backdrop may touch the window only while the active theme sets a window background, and
//  has to hand back the exact original color when it stops.
//

import AppKit
@testable import TablePro
import Testing

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two.
@Suite("The window backdrop follows the theme", .serialized)
@MainActor
struct ThemeWindowBackdropTests {
    private static let windowHex = "#282A36"

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func makeWindow(_ appearance: NSAppearance.Name = .darkAqua) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        return window
    }

    private func theme(_ appearance: ThemeAppearance, window hex: String?) throws -> ThemeDefinition {
        var theme = BuiltInThemes.default(for: appearance)
        guard let hex else { return theme }
        theme.id = "user.test.backdrop-\(appearance.rawValue)"
        theme.overrides[.windowBackdrop] = try ThemeColor(validating: hex)
        return theme
    }

    private func adopt(light: ThemeDefinition = BuiltInThemes.light, dark: ThemeDefinition, effective: ThemeAppearance = .dark) {
        ThemeTestFixture.adopt(ThemePair(light: light, dark: dark), appearance: effective)
    }

    private func hex(of color: NSColor?, in window: NSWindow) throws -> String {
        let color = try #require(color)
        var hex = ""
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    private var drawsBackdrop: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    @Test("The default pair leaves the window's own background untouched")
    func defaultPairLeavesTheWindowAlone() throws {
        try ThemeTestFixture.preservingEngine {
            adopt(dark: BuiltInThemes.dark)
            let window = makeWindow()
            let original = window.backgroundColor

            let backdrop = ThemeWindowBackdrop(window: window)
            #expect(window.backgroundColor === original)
            #expect(window.backgroundColor == NSColor.windowBackgroundColor)

            adopt(dark: BuiltInThemes.dark, effective: .light)
            backdrop.apply()
            #expect(window.backgroundColor === original)
        }
    }

    @Test("A theme that sets the window background fills the window, and switching back restores the original")
    func overrideFillsAndRestores() throws {
        try ThemeTestFixture.preservingEngine {
            adopt(dark: BuiltInThemes.dark)
            let window = makeWindow()
            let original = window.backgroundColor
            let backdrop = ThemeWindowBackdrop(window: window)

            adopt(dark: try theme(.dark, window: Self.windowHex))
            if drawsBackdrop {
                #expect(try hex(of: window.backgroundColor, in: window) == Self.windowHex)
            } else {
                #expect(window.backgroundColor === original)
            }

            adopt(dark: BuiltInThemes.dark)
            #expect(window.backgroundColor == original)
            #expect(window.backgroundColor == NSColor.windowBackgroundColor)
            withExtendedLifetime(backdrop) {}
        }
    }

    @Test("A light-only window background leaves a dark window alone, and the flip to light fills it")
    func onlyTheActiveThemeCounts() throws {
        try ThemeTestFixture.preservingEngine {
            let light = try theme(.light, window: "#F0E8D8")
            adopt(light: light, dark: BuiltInThemes.dark, effective: .dark)
            let window = makeWindow(.darkAqua)
            let original = window.backgroundColor
            let backdrop = ThemeWindowBackdrop(window: window)
            #expect(window.backgroundColor === original)

            window.appearance = NSAppearance(named: .aqua)
            adopt(light: light, dark: BuiltInThemes.dark, effective: .light)
            if drawsBackdrop {
                #expect(try hex(of: window.backgroundColor, in: window) == "#F0E8D8")
            } else {
                #expect(window.backgroundColor === original)
            }
            withExtendedLifetime(backdrop) {}
        }
    }
}
