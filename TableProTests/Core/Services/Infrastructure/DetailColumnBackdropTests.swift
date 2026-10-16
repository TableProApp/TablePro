//
//  DetailColumnBackdropTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

/// Connecting, Unavailable and the agent conversation draw no backdrop of their own, so the theme
/// reaches them only through the detail column. Windows are never ordered front and never closed.
@MainActor
struct DetailColumnBackdropTests {
    private static let size = NSSize(width: 400, height: 300)

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        let x = min(bitmap.pixelsWide - 1, Int(CGFloat(bitmap.pixelsWide) * point.x))
        let y = min(bitmap.pixelsHigh - 1, Int(CGFloat(bitmap.pixelsHigh) * point.y))
        return try #require(ThemeTestFixture.pixel(bitmap, x: x, y: y))
    }

    private func window(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        return window
    }

    /// Drawn through the same path as the column, so the capture's color management cancels out.
    private func reference(_ style: some ShapeStyle) throws -> NSColor {
        let host = NSHostingView(rootView: Rectangle().fill(style))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = window(containing: host)
        defer { window.contentView = nil }
        return try pixel(snapshot(host), at: CGPoint(x: 0.5, y: 0.5))
    }

    /// The detail column the main window builds, showing a pane that draws nothing, the way the
    /// Connecting screen leaves the area around its message.
    private func column(withBackdrop: Bool) -> (host: WorkspacePaneHost, window: NSWindow) {
        let host = WorkspacePaneHost()
        if withBackdrop {
            host.installBackdrop(DetailColumnBackdrop.makeView())
        }
        let pane = NSHostingController(rootView: AnyView(Color.clear))
        pane.sizingOptions = []
        host.show(pane)
        host.view.frame = NSRect(origin: .zero, size: Self.size)
        return (host, window(containing: host.view))
    }

    @Test("The detail column draws the window theme under a pane with no backdrop of its own")
    func themedUnderABarePane() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let theme = try reference(Color(nsColor: HexColor.color(ThemeTestFixture.windowHex)))
            let (host, window) = column(withBackdrop: true)
            defer { window.contentView = nil }
            let drawn = try pixel(snapshot(host.view), at: CGPoint(x: 0.1, y: 0.9))
            #expect(ThemeTestFixture.matches(drawn, theme), "drew \(drawn), theme \(theme)")
        }
    }

    @Test("Under the default pair the detail column draws the system background")
    func defaultDrawsTheSystemBackground() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try reference(.background)
            let (host, window) = column(withBackdrop: true)
            defer { window.contentView = nil }
            let drawn = try pixel(snapshot(host.view), at: CGPoint(x: 0.1, y: 0.9))
            #expect(ThemeTestFixture.matches(drawn, native), "drew \(drawn), native \(native)")
        }
    }

    @Test("Without the backdrop the same pane shows nothing, which is what the window drew through")
    func withoutTheBackdropNothingIsDrawn() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let (host, window) = column(withBackdrop: false)
            defer { window.contentView = nil }
            let drawn = try pixel(snapshot(host.view), at: CGPoint(x: 0.1, y: 0.9))
            #expect(drawn.alphaComponent < 0.05, "drew \(drawn)")
        }
    }

    @Test("A pane shown later still sits above the backdrop, and the backdrop never takes a click")
    func backdropStaysBelowAndPassesClicks() throws {
        let (host, window) = column(withBackdrop: true)
        defer { window.contentView = nil }
        let backdrop = try #require(host.view.subviews.first)
        #expect(backdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)

        let next = NSViewController()
        next.view = NSView()
        host.show(next)
        #expect(host.view.subviews.first === backdrop)
        #expect(host.view.subviews.last === next.view)
    }

    @Test("The main window's Connecting screen sits on the window theme")
    func mainWindowConnectingIsThemed() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let theme = try reference(Color(nsColor: HexColor.color(ThemeTestFixture.windowHex)))
            let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
            defer { fixture.tearDown() }
            fixture.window.appearance = NSAppearance(named: .darkAqua)
            #expect(fixture.workspace.resolvedPane == .connecting)

            let drawn = try pixel(snapshot(fixture.split.detailPaneHost.view), at: CGPoint(x: 0.05, y: 0.95))
            #expect(ThemeTestFixture.matches(drawn, theme), "drew \(drawn), theme \(theme)")
        }
    }
}
