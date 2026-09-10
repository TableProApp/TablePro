//
//  CellOverlayAppearanceTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// `appAppearanceChangeRepaintsAnOpenOverlay` assigns `NSApp.appearance`, which is global. What keeps
/// that from reaching a suite running in parallel is that the body is synchronous and `@MainActor`,
/// so nothing else on the main actor can interleave before the `defer` restores it. `.serialized`
/// only orders tests inside this suite. Adding an `await` would break it.
@Suite("Cell overlay layer colours follow the appearance", .serialized)
@MainActor
struct CellOverlayAppearanceTests {
    private func makeContainer() -> CellOverlayContainerView {
        CellOverlayBase.makeContainer(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    }

    private func components(of color: CGColor?) throws -> (brightness: CGFloat, alpha: CGFloat) {
        let cgColor = try #require(color)
        let nsColor = try #require(NSColor(cgColor: cgColor))
        let srgb = try #require(nsColor.usingColorSpace(.sRGB))
        let brightness = (srgb.redComponent + srgb.greenComponent + srgb.blueComponent) / 3
        return (brightness, srgb.alphaComponent)
    }

    @Test("A container built under each appearance gets that appearance's colours")
    func containerColoursDifferByAppearance() throws {
        let light = makeContainer()
        light.appearance = try #require(NSAppearance(named: .aqua))
        let dark = makeContainer()
        dark.appearance = try #require(NSAppearance(named: .darkAqua))

        let lightBackground = try components(of: light.layer?.backgroundColor)
        let darkBackground = try components(of: dark.layer?.backgroundColor)
        let lightBorder = try components(of: light.layer?.borderColor)
        let darkBorder = try components(of: dark.layer?.borderColor)

        #expect(lightBackground.brightness > darkBackground.brightness)
        #expect(lightBorder.brightness != darkBorder.brightness)
    }

    /// The real trigger. `ThemeEngine.applyNSAppAppearance` assigns `NSApp.appearance`, and on that
    /// path a view's `effectiveAppearance` is already the new one while
    /// `NSAppearance.currentDrawing()` is still the old one, so a bare `.cgColor` resolves to the old
    /// colour. Setting `container.appearance` directly does not reproduce that and would pass even
    /// without `performAsCurrentDrawingAppearance`. The container has to be in a real window.
    ///
    /// The window has to be held across the flip. AppKit does not retain a window that was never
    /// ordered front, and this one's last use is the `contentView` read below, so an autorelease pool
    /// draining between that and the flip deallocates it. Measured: after a pool drain the window is
    /// gone, `NSApp.windows` is empty, the container's `window` is nil, and the appearance change
    /// produces zero `viewDidChangeEffectiveAppearance` calls, leaving `effectiveAppearance` at Aqua
    /// and both reads at the light colour. That is the failure this suite showed once and could not
    /// explain, and it is intermittent because where the pool drains is not the test's to decide.
    @Test("An app appearance change repaints an open overlay")
    func appAppearanceChangeRepaintsAnOpenOverlay() throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }

        NSApp.appearance = try #require(NSAppearance(named: .aqua))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let contentView = try #require(window.contentView)
        contentView.addSubview(tableView)

        let container = makeContainer()
        tableView.addSubview(container)

        try withExtendedLifetime(window) {
            let lightBackground = try components(of: container.layer?.backgroundColor)
            let lightBorder = try components(of: container.layer?.borderColor)

            NSApp.appearance = try #require(NSAppearance(named: .darkAqua))

            #expect(container.window === window)
            #expect(container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

            let darkBackground = try components(of: container.layer?.backgroundColor)
            let darkBorder = try components(of: container.layer?.borderColor)

            #expect(lightBackground.brightness > darkBackground.brightness)
            #expect(lightBorder.brightness != darkBorder.brightness)
        }
    }
}
