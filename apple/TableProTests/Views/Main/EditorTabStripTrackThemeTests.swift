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
        try color(of: view, atFraction: 0.5)
    }

    // Left of a tab's centred title, inside its capsule.
    private static func color(of view: NSView, atFraction fraction: CGFloat) throws -> NSColor {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = Int(CGFloat(bitmap.pixelsWide) * fraction)
        let color = try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    @Test(
        "On an opaque titlebar's vibrant strip the track and the selected tab draw as on the transparent titlebar",
        arguments: [(NSAppearance.Name.vibrantDark, NSAppearance.Name.darkAqua), (.vibrantLight, .aqua)]
    )
    func vibrantStripDrawsLikeTheTransparentTitlebar(names: (vibrant: NSAppearance.Name, plain: NSAppearance.Name)) throws {
        // Never ordered front and never closed: `close()` on a test window over-releases it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: names.plain)
        let track = EditorTabTrackView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        let tab = EditorTabItemView(item: .sample(isSelected: true))
        tab.frame = NSRect(x: 0, y: 50, width: 160, height: 28)
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            for view in [track, tab] as [NSView] {
                window.contentView?.addSubview(view)
                defer { view.removeFromSuperview() }
                view.appearance = nil
                let plain = try Self.color(of: view, atFraction: 0.15)
                view.appearance = NSAppearance(named: names.vibrant)
                let vibrant = try Self.color(of: view, atFraction: 0.15)
                #expect(ThemeTestFixture.matches(plain, vibrant), "\(type(of: view)) drew \(vibrant), not \(plain)")
            }
        }
    }

    @Test("On an opaque titlebar's vibrant strip a window theme leaves the track the system's own")
    func vibrantStripKeepsTheSystemTrackUnderATheme() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let vibrant = try #require(NSAppearance(named: .vibrantDark))
            let plain = try #require(NSAppearance(named: .darkAqua))
            #expect(!EditorTabStripPalette.isOverThemedBackdrop(in: vibrant, highContrast: false))
            #expect(
                EditorTabStripPalette.isOverThemedBackdrop(in: plain, highContrast: false)
                    == EditorTabStripPalette.followsWindowBackdrop
            )
        }
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
