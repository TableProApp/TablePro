//
//  EditorTabStripAccessoryControllerTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

/// Three of these properties look like configuration and are really correctness. Probing a bottom
/// titlebar accessory on macOS 27 shows `automaticallyAdjustsSize` resizing the band to the
/// system's own height when left at its default, and `fullScreenMinHeight` clipping the band to a
/// stale value in full screen while the windowed layout still looks right. `fullScreenMinHeight`
/// left at its default of zero measured as zero drawn pixels once the menu bar auto-hid: the strip
/// disappears on entering full screen and does not come back for the rest of the session.
@Suite("Editor tab strip accessory")
@MainActor
struct EditorTabStripAccessoryControllerTests {
    @Test("The band is configured as a bottom accessory that keeps its own height")
    func bandConfiguration() {
        let accessory = EditorTabStripAccessoryController()
        _ = accessory.view

        #expect(accessory.layoutAttribute == .bottom)
        #expect(!accessory.automaticallyAdjustsSize)
        #expect(accessory.view.frame.height == EditorTabStripLayout.bandHeight)
    }

    /// The header's rule is that a fully shown accessory sets this to the view's height, "and be
    /// sure to update it if you ever change the view's height". Asserting the equality rather than
    /// the literal is what makes a future height change fail here instead of in full screen.
    @Test("Full screen keeps the whole band rather than clipping it")
    func fullScreenMinHeightMatchesTheBand() {
        let accessory = EditorTabStripAccessoryController()
        _ = accessory.view

        #expect(accessory.fullScreenMinHeight == accessory.view.frame.height)
        #expect(accessory.fullScreenMinHeight > 0)
    }

    @Test("Hiding the band collapses it without taking it off the window")
    func bandVisibilityToggles() {
        let accessory = EditorTabStripAccessoryController()
        _ = accessory.view

        accessory.setBandVisible(false)
        #expect(accessory.isHidden)

        accessory.setBandVisible(true)
        #expect(!accessory.isHidden)

        /// Idempotent, because it is driven from every pane-chrome pass rather than from an edge.
        accessory.setBandVisible(true)
        #expect(!accessory.isHidden)
    }

    @Test("The band shows one connection's strip at a time and swaps rather than stacking")
    func bandSwapsHostedStrip() {
        let accessory = EditorTabStripAccessoryController()
        _ = accessory.view

        let first = NSViewController()
        first.view = NSView()
        let second = NSViewController()
        second.view = NSView()

        accessory.show(first)
        #expect(first.view.superview != nil)

        accessory.show(second)
        #expect(second.view.superview != nil)
        #expect(first.view.superview == nil)

        /// A window with no connection selected shows no strip, rather than keeping the last one
        /// on screen and through it the coordinator that strip retains.
        accessory.show(nil)
        #expect(second.view.superview == nil)
    }
}
