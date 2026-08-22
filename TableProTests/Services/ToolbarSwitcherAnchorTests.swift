//
//  ToolbarSwitcherAnchorTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

/// The switcher anchors to a toolbar item when one is there and falls back to an unanchored panel
/// when it is not. Getting that decision wrong is not a layout glitch: `NSPopover.show(relativeTo:)`
/// throws `NSInvalidArgumentException` when it cannot locate the item, and Swift cannot catch it,
/// so this is the guard that keeps a missing anchor from being a crash.
@Suite("ToolbarSwitcherPresenter anchor resolution")
@MainActor
struct ToolbarSwitcherAnchorTests {
    private static let identifier = NSToolbarItem.Identifier("com.TablePro.tests.anchor")

    private final class Delegate: NSObject, NSToolbarDelegate {
        var identifiers: [NSToolbarItem.Identifier]

        init(identifiers: [NSToolbarItem.Identifier]) {
            self.identifiers = identifiers
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            NSToolbarItem(itemIdentifier: itemIdentifier)
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            identifiers
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            identifiers
        }
    }

    /// Returned so the caller can hold it with `withExtendedLifetime`: `NSToolbar` keeps its
    /// delegate weakly, and a deallocated one leaves a toolbar with no items, which would make every
    /// case here "pass" for the wrong reason.
    private func makeWindow(containing identifiers: [NSToolbarItem.Identifier]) -> (NSWindow, Delegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let delegate = Delegate(identifiers: identifiers)
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.toolbar")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        /// Set rather than assumed: a window that is never ordered front does not report a visible
        /// toolbar, so leaving this to the default made the anchored case look like the unanchored
        /// one and the test passed for the wrong reason.
        toolbar.isVisible = true
        return (window, delegate)
    }

    @Test("An item in a visible toolbar is the anchor")
    func resolvesItemInVisibleToolbar() {
        let (window, delegate) = makeWindow(containing: [Self.identifier])
        withExtendedLifetime(delegate) {
            let item = ToolbarSwitcherPresenter.anchor(in: window, Self.identifier)
            #expect(item?.itemIdentifier == Self.identifier)
        }
    }

    /// What Customize Toolbar leaves behind. A clipped item is a different state and keeps its
    /// place in `toolbar.items`, so it still resolves and still takes the popover branch; that one
    /// needs a real overflowing toolbar and so is not reachable from a unit test.
    @Test("An item the toolbar does not carry has no anchor")
    func missingItemHasNoAnchor() {
        let (window, delegate) = makeWindow(containing: [])
        withExtendedLifetime(delegate) {
            #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier) == nil)
        }
    }

    /// View > Hide Toolbar only flips `isVisible` and leaves the items in place, so the item still
    /// resolves. Anchoring to an item in a hidden toolbar is undocumented, and the cost of being
    /// wrong is an uncatchable exception, so a hidden toolbar counts as no anchor.
    @Test("A hidden toolbar has no anchor even though it still carries the item")
    func hiddenToolbarHasNoAnchor() {
        let (window, delegate) = makeWindow(containing: [Self.identifier])
        withExtendedLifetime(delegate) {
            window.toolbar?.isVisible = false

            #expect(window.toolbar?.items.contains { $0.itemIdentifier == Self.identifier } == true)
            #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier) == nil)
        }
    }

    @Test("A window with no toolbar has no anchor")
    func windowWithoutToolbarHasNoAnchor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier) == nil)
    }

    @Test("No window has no anchor")
    func noWindowHasNoAnchor() {
        #expect(ToolbarSwitcherPresenter.anchor(in: nil, Self.identifier) == nil)
    }
}
