//
//  SplitItemBackdropTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

// Reduce Transparency is passed in, never read: the CI image runs with it on.
@MainActor
struct SplitItemBackdropTests {
    private static let center = CGPoint(x: 0.5, y: 0.5)

    private func pane(reduceTransparency: Bool, reachesChrome: Bool = true) -> some View {
        Color.clear
            .frame(width: 80, height: 80)
            .modifier(SplitItemBackdropFill(reduceTransparency: reduceTransparency, reachesChrome: reachesChrome))
    }

    @Test("The pane fills only on macOS 26 and later, under Reduce Transparency, with a themed window")
    func gateNeedsAllThree() {
        for reachesChrome in [false, true] {
            for reduceTransparency in [false, true] {
                for isThemed in [false, true] {
                    let fills = SplitItemBackdrop.fills(
                        reachesChrome: reachesChrome,
                        reduceTransparency: reduceTransparency,
                        isThemed: isThemed
                    )
                    #expect(fills == (reachesChrome && reduceTransparency && isThemed))
                }
            }
        }
    }

    @Test("Under Reduce Transparency the pane draws the window theme")
    func reduceTransparencyDrawsTheWindowTheme() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let theme = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            let drawn = try ThemeTestFixture.color(of: pane(reduceTransparency: true), at: Self.center, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, theme), "drew \(drawn), theme \(theme)")
        }
    }

    @Test("With transparency on the pane draws nothing, so the glass shows")
    func glassShowsWithoutReduceTransparency() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: pane(reduceTransparency: false), at: Self.center, colorScheme: .dark)
            #expect(drawn.alphaComponent < 0.05, "drew \(drawn)")
        }
    }

    @Test("A theme without a window color leaves the system fill alone")
    func defaultThemeDrawsNothing() throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: pane(reduceTransparency: true), at: Self.center, colorScheme: .dark)
            #expect(drawn.alphaComponent < 0.05, "drew \(drawn)")
        }
    }

    @Test("Before macOS 26 the sidebar never took the theme, so it stays system")
    func noFillBeforeTheBackdropRelease() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let drawn = try ThemeTestFixture.color(
                of: pane(reduceTransparency: true, reachesChrome: false),
                at: Self.center,
                colorScheme: .dark
            )
            #expect(drawn.alphaComponent < 0.05, "drew \(drawn)")
        }
    }

    @Test("Increase Contrast keeps the system fill")
    func increaseContrastIsNotThemed() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            #expect(ThemeBackdropState.isThemed(highContrast: false))
            #expect(!ThemeBackdropState.isThemed(highContrast: true))
        }
    }

    @Test("The backdrop never takes a click")
    func backdropPassesClicks() {
        let backdrop = SplitItemBackdrop.makeView(reduceTransparency: true)
        backdrop.frame = NSRect(x: 0, y: 0, width: 80, height: 80)
        #expect(backdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test("The main window's sidebar and inspector sit on the backdrop, over the full pane")
    func mainWindowPanesHaveTheBackdrop() throws {
        let fixture = try OffscreenConnectionWindow(size: CGSize(width: 1_200, height: 800))
        defer { fixture.tearDown() }
        fixture.setInspectorOpen(true)

        let sidebar = fixture.split.sidebarSplitItem.viewController.view
        let sidebarBackdrop = try #require(sidebar.subviews.first)
        #expect(String(describing: type(of: sidebarBackdrop)).contains("SplitItemBackdrop"))
        #expect(sidebarBackdrop.frame == sidebar.bounds)

        let inspector = fixture.split.inspectorPaneHost.view
        let inspectorBackdrop = try #require(inspector.subviews.first)
        #expect(String(describing: type(of: inspectorBackdrop)).contains("SplitItemBackdrop"))
        #expect(inspectorBackdrop.frame == inspector.bounds)
    }

    // The one case that follows this Mac's setting: the view reads it from its environment.
    @Test("The data file inspector fills with the window theme exactly while this Mac reduces transparency")
    func dataFileInspectorFollowsReduceTransparency() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let host = NSHostingView(rootView: DataFileRowDetailsView(controller: DataFileDocument().controller))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.contentView = nil }

            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let drawn = try #require(ThemeTestFixture.pixel(bitmap, x: 4, y: bitmap.pixelsHigh - 4))

            let fills = ThemeWindowBackdrop.canReachChrome && NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            if fills {
                let theme = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
                #expect(ThemeTestFixture.matches(drawn, theme, tolerance: 0.04), "drew \(drawn), theme \(theme)")
            } else {
                #expect(drawn.alphaComponent < 0.05, "drew \(drawn)")
            }
        }
    }

    @Test("A bar over a sidebar or inspector keeps its material where the window color cannot reach it")
    func barsOnASplitItemNeedTheBackdropRelease() throws {
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            #expect(ThemeBackdropState.isThemed(highContrast: false, onSplitItem: false, reachesChrome: false))
            #expect(!ThemeBackdropState.isThemed(highContrast: false, onSplitItem: true, reachesChrome: false))
            #expect(ThemeBackdropState.isThemed(highContrast: false, onSplitItem: true, reachesChrome: true))
            #expect(!ThemeBackdropState.isThemed(highContrast: true, onSplitItem: true, reachesChrome: true))
        }
    }

    @Test("Under Reduce Transparency the license scrim is the window color its pane sits on")
    func solidScrimFollowsTheWindowTheme() throws {
        let scrim = AccessibleMaterialScrim(material: .ultraThinMaterial, reduceTransparency: true)
            .frame(width: 80, height: 80)
        try ThemeTestFixture.adopting([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark) {
            let theme = try ThemeTestFixture.filled(hex: ThemeTestFixture.windowHex, colorScheme: .dark)
            let drawn = try ThemeTestFixture.color(of: scrim, at: Self.center, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, theme), "drew \(drawn), theme \(theme)")
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let native = try ThemeTestFixture.filled(.windowBackgroundColor, colorScheme: .dark)
            let drawn = try ThemeTestFixture.color(of: scrim, at: Self.center, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, native), "drew \(drawn), native \(native)")
        }
    }
}
