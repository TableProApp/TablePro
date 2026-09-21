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
///
/// The decision reads the app's own record of what it hid and `NSToolbar.items`, and nothing
/// AppKit reports about visibility, because one Customize Toolbar visit is measured to leave
/// `visibleItems` and `NSToolbarItem.isVisible` over-reporting for good.
@Suite("ToolbarSwitcherPresenter anchor resolution")
@MainActor
struct ToolbarSwitcherAnchorTests {
    private static let identifier = NSToolbarItem.Identifier("com.TablePro.tests.anchor")
    private static let sibling = NSToolbarItem.Identifier("com.TablePro.tests.anchor.sibling")

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
    private func makeWindow(
        containing identifiers: [NSToolbarItem.Identifier],
        width: CGFloat = 800
    ) -> (NSWindow, Delegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
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
            let item = ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: nil)
            #expect(item?.itemIdentifier == Self.identifier)
        }
    }

    /// What Customize Toolbar leaves behind. A clipped item is a different state and keeps its
    /// place in `toolbar.items`, so it still resolves and still takes the popover branch.
    @Test("An item the toolbar does not carry has no anchor")
    func missingItemHasNoAnchor() {
        let (window, delegate) = makeWindow(containing: [])
        withExtendedLifetime(delegate) {
            #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: nil) == nil)
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
            #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: nil) == nil)
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

        #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: nil) == nil)
    }

    @Test("No window has no anchor")
    func noWindowHasNoAnchor() {
        #expect(ToolbarSwitcherPresenter.anchor(in: nil, Self.identifier, hiddenBy: nil) == nil)
    }

    /// An item the context took out of the titlebar is still in `toolbar.items`, because hiding is
    /// how the context is expressed. A popover anchored on it lands at the window's centre, measured,
    /// attached to nothing, so the record sends the chooser to the floating panel instead.
    @Test("An item the context hid has no anchor, although the toolbar still carries it")
    func hiddenItemHasNoAnchor() {
        let (window, delegate) = makeWindow(containing: [Self.identifier, Self.sibling])
        withExtendedLifetime(delegate) {
            let visibility = ToolbarVisibility(hidden: [Self.identifier])

            #expect(window.toolbar?.items.contains { $0.itemIdentifier == Self.identifier } == true)
            #expect(ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: visibility) == nil)
        }
    }

    /// Hiding one of the centred pair is the file-based case, and the other has to keep its anchor.
    @Test("An item the context did not hide still anchors beside one it did")
    func siblingOfAHiddenItemAnchors() {
        let (window, delegate) = makeWindow(containing: [Self.identifier, Self.sibling])
        withExtendedLifetime(delegate) {
            let visibility = ToolbarVisibility(hidden: [Self.sibling])
            let anchor = ToolbarSwitcherPresenter.anchor(in: window, Self.identifier, hiddenBy: visibility)
            #expect(anchor?.itemIdentifier == Self.identifier)
        }
    }

    /// Nil is a toolbar with no context resolver, which hides nothing, so everything the toolbar
    /// carries resolves.
    @Test("With no record, everything the toolbar carries resolves")
    func noRecordHidesNothing() {
        let (window, delegate) = makeWindow(containing: [Self.identifier, Self.sibling])
        withExtendedLifetime(delegate) {
            for identifier in [Self.identifier, Self.sibling] {
                let anchor = ToolbarSwitcherPresenter.anchor(in: window, identifier, hiddenBy: nil)
                #expect(anchor?.itemIdentifier == identifier)
            }
        }
    }

    /// A clipped top-level item still resolves, because the answer comes from `toolbar.items`
    /// rather than from anything that reports what is laid out. AppKit anchors the popover on the
    /// clipped-items indicator itself, measured on macOS 27 with no raise in any state.
    @Test("An item resolves whether or not the window has room for it")
    func resolvesWhateverTheWidth() {
        let identifiers = (0..<12).map { NSToolbarItem.Identifier("com.TablePro.tests.anchor.\($0)") }
        let (window, delegate) = makeWindow(containing: identifiers, width: 120)
        withExtendedLifetime(delegate) {
            let last = identifiers[identifiers.count - 1]
            let anchor = ToolbarSwitcherPresenter.anchor(in: window, last, hiddenBy: ToolbarVisibility())
            #expect(anchor?.itemIdentifier == last)
        }
    }
}
