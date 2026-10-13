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
        try ThemeSurfaceProbe.adopting(dark: BuiltInThemes.dark) {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let track = try resolved(EditorTabStripPalette.trackFill, in: name)
                let system = try native(in: name)
                #expect(ThemeSurfaceProbe.matches(track, system), "\(name.rawValue) drew \(track)")
            }
        }
    }

    @Test("A theme that sets the window background takes the track in its own appearance only")
    func windowThemeTakesTheTrack() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([.windowBackdrop: ThemeSurfaceProbe.windowHex])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let dark = try resolved(EditorTabStripPalette.trackFill, in: .darkAqua)
            #expect(HexColor.string(from: dark) == ThemeSurfaceProbe.windowHex)

            let light = try resolved(EditorTabStripPalette.trackFill, in: .aqua)
            let system = try native(in: .aqua)
            #expect(ThemeSurfaceProbe.matches(light, system), "light drew \(light)")
        }
    }

    @Test("Editor and grid colors leave the track alone")
    func contentSlotsLeaveTheTrackAlone() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([
            .editorBackground: ThemeSurfaceProbe.editorHex,
            .gridBackground: ThemeSurfaceProbe.gridHex,
        ])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let track = try resolved(EditorTabStripPalette.trackFill, in: .darkAqua)
            let system = try native(in: .darkAqua)
            #expect(ThemeSurfaceProbe.matches(track, system), "drew \(track)")
        }
    }

    @Test("A theme change repaints a track already on screen")
    func trackRepaintsOnThemeChange() throws {
        let track = Self.host(Color.clear.modifier(EditorTabStripTrackSurface(rowCount: 1)))
        let reference = try Self.center(of: Self.host(Color(nsColor: HexColor.color(ThemeSurfaceProbe.windowHex))))
        let theme = try ThemeSurfaceProbe.darkTheme([.windowBackdrop: ThemeSurfaceProbe.windowHex])
        try ThemeSurfaceProbe.adopting(dark: BuiltInThemes.dark) {
            let before = try Self.center(of: track)
            #expect(!ThemeSurfaceProbe.matches(before, reference), "default drew \(before)")
            ThemeSurfaceProbe.adopt(dark: theme)
            let after = try Self.center(of: track)
            #expect(ThemeSurfaceProbe.matches(after, reference), "themed drew \(after), theme \(reference)")
        }
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private static func host(_ view: some View) -> NSHostingView<AnyView> {
        let size = NSSize(width: 120, height: 40)
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

    private static func center(of host: NSHostingView<AnyView>) throws -> NSColor {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try #require(color.usingColorSpace(.sRGB))
    }

    @Test("The selected tab stays the system's own fill under a theme")
    func selectedTabStaysSystem() throws {
        let theme = try ThemeSurfaceProbe.darkTheme([.windowBackdrop: ThemeSurfaceProbe.windowHex])
        try ThemeSurfaceProbe.adopting(dark: theme) {
            let selected = try resolved(EditorTabStripPalette.selectedFill, in: .darkAqua)
            let system = try resolved(Color(nsColor: .controlColor), in: .darkAqua)
            #expect(ThemeSurfaceProbe.matches(selected, system))
        }
    }
}
