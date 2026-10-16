//
//  EditorTabStripTrackThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct EditorTabStripTrackThemeTests {
    private func resolved(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return try #require(result)
    }

    private func native(in name: NSAppearance.Name) throws -> NSColor {
        try resolved(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: name)
    }

    private var isOverThemedBackdrop: Bool {
        EditorTabStripPalette.isOverThemedBackdrop(highContrast: false)
    }

    @Test("The default pair keeps the system track in both appearances")
    func defaultPairKeepsTheSystemTrack() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(!isOverThemedBackdrop)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let track = try resolved(EditorTabStripPalette.trackFill(overThemedBackdrop: isOverThemedBackdrop), in: name)
                #expect(ThemeTestFixture.matches(track, try native(in: name)), "\(name.rawValue) drew \(track)")
            }
        }
    }

    @Test("Where the window takes the theme, a window theme puts the track over it, unless Increase Contrast is on")
    func windowThemeMovesTheTrack() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            #expect(isOverThemedBackdrop == EditorTabStripPalette.followsWindowBackdrop)
            #expect(!EditorTabStripPalette.isOverThemedBackdrop(highContrast: true))
        }
    }

    @Test("Over a themed window the track is a translucent system fill, never the theme's own color")
    func themedTrackIsATranslucentSystemFill() throws {
        guard #available(macOS 14.0, *) else { return }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let track = try resolved(EditorTabStripPalette.trackFill(overThemedBackdrop: true), in: name)
            let fill = try resolved(Color(nsColor: .secondarySystemFill), in: name)
            #expect(ThemeTestFixture.matches(track, fill), "\(name.rawValue) drew \(track)")
            #expect(track.alphaComponent < 0.5, "\(name.rawValue) drew \(track)")
        }
    }

    @Test("The track follows the window backdrop on macOS 26 and later only")
    func gateFollowsTheBackdropRelease() {
        let backdropRelease = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let expected = ProcessInfo.processInfo.isOperatingSystemAtLeast(backdropRelease)
        #expect(EditorTabStripPalette.followsWindowBackdrop == expected)
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    @Test("The track moves exactly when a content window's backdrop takes the theme")
    func trackMatchesTheWindowBackdrop() throws {
        let windowTheme = try ThemeTestFixture.pair([.windowBackdrop: ThemeTestFixture.windowHex], on: .dark)
        let editorTheme = try ThemeTestFixture.pair([.editorBackground: ThemeTestFixture.editorHex], on: .dark)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            for theme in [ThemePair.builtIn, windowTheme, editorTheme] {
                ThemeTestFixture.adopt(theme, appearance: .dark)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                let original = window.backgroundColor
                let backdrop = ThemeWindowBackdrop(window: window)
                let windowThemed = window.backgroundColor !== original

                #expect(windowThemed == isOverThemedBackdrop, "\(theme.dark.id): window themed \(windowThemed)")
                withExtendedLifetime(backdrop) {}
            }
        }
    }

    @Test("Editor and grid colors leave the track alone")
    func contentSlotsLeaveTheTrackAlone() throws {
        try ThemeTestFixture.adopting([
            .editorBackground: ThemeTestFixture.editorHex,
            .gridBackground: ThemeTestFixture.gridHex,
        ], appearance: .dark) {
            #expect(!isOverThemedBackdrop)
        }
    }

    @Test("A theme change repaints a track already on screen")
    func trackRepaintsOnThemeChange() throws {
        let track = Self.host(Color.clear.modifier(EditorTabStripTrackSurface(rowCount: 1)))
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let before = try Self.center(of: track)
            let system = try Self.center(of: Self.host(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)))
            #expect(ThemeTestFixture.matches(before, system), "default drew \(before), system \(system)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let after = try Self.center(of: track)
            let expected = try Self.center(of: Self.host(
                Color(nsColor: EditorTabStripPalette.trackColor(overThemedBackdrop: EditorTabStripPalette.followsWindowBackdrop))
            ))
            #expect(ThemeTestFixture.matches(after, expected), "themed drew \(after), expected \(expected)")
        }
    }

    private static func host(_ view: some View) -> NSHostingView<AnyView> {
        ThemeTestFixture.hostingView(view, size: NSSize(width: 120, height: 40))
    }

    private static func center(of host: NSHostingView<AnyView>) throws -> NSColor {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    @Test("The selected tab stays the system's own fill under a theme")
    func selectedTabStaysSystem() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let selected = try resolved(EditorTabStripPalette.selectedFill, in: .darkAqua)
            let system = try resolved(Color(nsColor: .controlColor), in: .darkAqua)
            #expect(ThemeTestFixture.matches(selected, system))
        }
    }
}
