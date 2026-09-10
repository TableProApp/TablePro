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
        let groupIdentifier: NSToolbarItem.Identifier
        let subitemIdentifiers: [NSToolbarItem.Identifier]

        init(
            identifiers: [NSToolbarItem.Identifier],
            groupIdentifier: NSToolbarItem.Identifier,
            subitemIdentifiers: [NSToolbarItem.Identifier]
        ) {
            self.identifiers = identifiers
            self.groupIdentifier = groupIdentifier
            self.subitemIdentifiers = subitemIdentifiers
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            guard itemIdentifier == groupIdentifier else {
                return NSToolbarItem(itemIdentifier: itemIdentifier)
            }
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.subitems = subitemIdentifiers.map { NSToolbarItem(itemIdentifier: $0) }
            return group
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
        let delegate = Delegate(
            identifiers: identifiers,
            groupIdentifier: Self.groupIdentifier,
            subitemIdentifiers: [Self.leadingIdentifier, Self.trailingIdentifier]
        )
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

    // MARK: - Group subitems

    private static let groupIdentifier = NSToolbarItem.Identifier("com.TablePro.tests.anchor.group")
    private static let leadingIdentifier = NSToolbarItem.Identifier("com.TablePro.tests.anchor.leading")
    private static let trailingIdentifier = NSToolbarItem.Identifier("com.TablePro.tests.anchor.trailing")

    private func makeGroup() -> NSToolbarItemGroup {
        let group = NSToolbarItemGroup(itemIdentifier: Self.groupIdentifier)
        group.subitems = [
            NSToolbarItem(itemIdentifier: Self.leadingIdentifier),
            NSToolbarItem(itemIdentifier: Self.trailingIdentifier),
        ]
        return group
    }

    /// The centred pair are subitems of one group, and the group is two capsules wide. Anchoring
    /// both choosers to the group put each of them on the seam between the capsules: measured on a
    /// 1200pt window, the group's midpoint is 600.0 while the two capsules sit at 543.2 and 671.8.
    @Test("A subitem of a visible group is the anchor, not the group")
    func resolvesSubitemOfVisibleGroup() {
        let group = makeGroup()

        let anchor = ToolbarSwitcherPresenter.anchor(Self.trailingIdentifier, in: [group], visible: [group])

        #expect(anchor?.itemIdentifier == Self.trailingIdentifier)
    }

    /// A subitem of a clipped group has no view, and `NSPopover.show(relativeTo:)` raises
    /// `NSInvalidArgumentException` for one, which Swift cannot catch. The group still resolves,
    /// because AppKit presents a clipped item from another affordance in the window itself.
    @Test("A subitem of an overflowed group falls back to the group")
    func fallsBackToOverflowedGroup() {
        let group = makeGroup()

        let anchor = ToolbarSwitcherPresenter.anchor(Self.leadingIdentifier, in: [group], visible: [])

        #expect(anchor?.itemIdentifier == Self.groupIdentifier)
    }

    /// What Customize Toolbar leaves behind for the centred pair: neither subitem is an allowed
    /// identifier of its own, so removing the group takes both choosers' anchors with it.
    @Test("A subitem of a group the toolbar does not carry has no anchor")
    func missingGroupHasNoAnchor() {
        #expect(ToolbarSwitcherPresenter.anchor(Self.leadingIdentifier, in: [], visible: []) == nil)
    }

    /// The toolbar's own item wins without consulting the visible list, which is what keeps a
    /// clipped top-level item resolving.
    @Test("A top-level item resolves even when it is not visible")
    func resolvesOverflowedTopLevelItem() {
        let item = NSToolbarItem(itemIdentifier: Self.identifier)

        let anchor = ToolbarSwitcherPresenter.anchor(Self.identifier, in: [item], visible: [])

        #expect(anchor?.itemIdentifier == Self.identifier)
    }

    /// The whole path both switchers take: an identifier that names no item of the toolbar still
    /// reaches the capsule it belongs to.
    @Test("The window lookup resolves a subitem of the toolbar's group")
    func windowLookupResolvesSubitem() {
        let (window, delegate) = makeWindow(containing: [Self.groupIdentifier])
        withExtendedLifetime(delegate) {
            #expect(window.toolbar?.items.contains { $0.itemIdentifier == Self.leadingIdentifier } == false)

            let anchor = ToolbarSwitcherPresenter.anchor(in: window, Self.leadingIdentifier)

            #expect(anchor?.itemIdentifier == Self.leadingIdentifier)
        }
    }
}
