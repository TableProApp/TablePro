//
//  EditorTabStripTrackThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("The tab strip track follows a theme's window color", .serialized)
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

    @Test("The default pair keeps the system track in both appearances")
    func defaultPairKeepsTheSystemTrack() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let track = try resolved(EditorTabStripPalette.trackFill, in: name)
                let system = try native(in: name)
                #expect(ThemeTestFixture.matches(track, system), "\(name.rawValue) drew \(track)")
            }
        }
    }

    private func track(followsWindowBackdrop: Bool) -> Color {
        Color(nsColor: EditorTabStripPalette.trackColor(followsWindowBackdrop: followsWindowBackdrop))
    }

    @Test("Where the window takes the theme, a theme that sets the window background takes the track in its own appearance only")
    func windowThemeTakesTheTrack() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let dark = try resolved(track(followsWindowBackdrop: true), in: .darkAqua)
            #expect(HexColor.string(from: dark) == ThemeTestFixture.windowHex)

            let light = try resolved(track(followsWindowBackdrop: true), in: .aqua)
            let system = try native(in: .aqua)
            #expect(ThemeTestFixture.matches(light, system), "light drew \(light)")
        }
    }

    @Test("Where the window keeps its system color, the track keeps the system fill under a window theme")
    func systemWindowKeepsTheTrack() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let drawn = try resolved(track(followsWindowBackdrop: false), in: name)
                let system = try native(in: name)
                #expect(ThemeTestFixture.matches(drawn, system), "\(name.rawValue) drew \(drawn)")
            }
        }
    }

    @Test("The track follows the window backdrop on macOS 26 and later only")
    func gateFollowsTheBackdropRelease() {
        let backdropRelease = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        let expected = ProcessInfo.processInfo.isOperatingSystemAtLeast(backdropRelease)
        #expect(EditorTabStripPalette.followsWindowBackdrop == expected)
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    @Test("The track takes the theme exactly when a content window's backdrop does")
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

                let drawn = try resolved(EditorTabStripPalette.trackFill, in: .darkAqua)
                let trackThemed = !ThemeTestFixture.matches(drawn, try native(in: .darkAqua))
                #expect(windowThemed == trackThemed, "\(theme.dark.id): window themed \(windowThemed), track drew \(drawn)")
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
            let track = try resolved(EditorTabStripPalette.trackFill, in: .darkAqua)
            let system = try native(in: .darkAqua)
            #expect(ThemeTestFixture.matches(track, system), "drew \(track)")
        }
    }

    @Test("A theme change repaints a track already on screen")
    func trackRepaintsOnThemeChange() throws {
        let track = Self.host(Color.clear.modifier(EditorTabStripTrackSurface(rowCount: 1)))
        let reference = try Self.center(of: Self.host(Color(nsColor: HexColor.color(ThemeTestFixture.windowHex))))
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let before = try Self.center(of: track)
            #expect(!ThemeTestFixture.matches(before, reference), "default drew \(before)")
            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let after = try Self.center(of: track)
            if EditorTabStripPalette.followsWindowBackdrop {
                #expect(ThemeTestFixture.matches(after, reference), "themed drew \(after), theme \(reference)")
            } else {
                #expect(ThemeTestFixture.matches(after, before), "themed drew \(after), system \(before)")
            }
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
