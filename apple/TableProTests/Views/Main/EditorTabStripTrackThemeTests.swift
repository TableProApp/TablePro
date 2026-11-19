//
//  EditorTabStripTrackThemeTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct EditorTabStripTrackThemeTests {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return try #require(result)
    }

    private var isOverThemedBackdrop: Bool {
        EditorTabStripPalette.isOverThemedBackdrop(highContrast: false)
    }

    @Test("The default pair keeps the system track in both appearances")
    func defaultPairKeepsTheSystemTrack() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            #expect(!isOverThemedBackdrop)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let track = try resolved(EditorTabStripPalette.trackColor(overThemedBackdrop: isOverThemedBackdrop), in: name)
                let native = try resolved(.unemphasizedSelectedContentBackgroundColor, in: name)
                #expect(ThemeTestFixture.matches(track, native), "\(name.rawValue) drew \(track)")
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
            let track = try resolved(EditorTabStripPalette.trackColor(overThemedBackdrop: true), in: name)
            let fill = try resolved(.secondarySystemFill, in: name)
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

    @Test("Editor and grid colors leave the track alone")
    func contentSlotsLeaveTheTrackAlone() throws {
        try ThemeTestFixture.adopting([
            .editorBackground: ThemeTestFixture.editorHex,
            .gridBackground: ThemeTestFixture.gridHex,
        ], appearance: .dark) {
            #expect(!isOverThemedBackdrop)
        }
    }

    @Test("The track draws the current theme each time it paints")
    func trackDrawsTheCurrentTheme() throws {
        let track = EditorTabTrackView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        track.appearance = NSAppearance(named: .darkAqua)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let before = try Self.center(of: track)
            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let after = try Self.center(of: track)
            #expect(ThemeTestFixture.matches(before, after) != EditorTabStripPalette.followsWindowBackdrop)
        }
    }

    private static func center(of view: NSView) throws -> NSColor {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    @Test("The selected tab stays the system's own fill under a theme")
    func selectedTabStaysSystem() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let selected = try resolved(EditorTabStripPalette.selectedColor, in: .darkAqua)
            let system = try resolved(.controlColor, in: .darkAqua)
            #expect(ThemeTestFixture.matches(selected, system))
        }
    }
}
