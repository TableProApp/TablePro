//
//  MainWindowToolbarContentModeTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// The mode control collapses into the toolbar's overflow menu at ordinary window widths, so the
/// menu form is the only way in for anyone whose window is not wide. It used to be AppKit's default
/// one, which sends the group's action with an `NSMenuItem` as the sender and nothing on it naming
/// a segment, so the action could not tell which mode had been chosen and every press from that
/// menu did nothing at all.
@MainActor
struct MainWindowToolbarContentModeTests {
    /// The owner comes back with the item. `NSMenuItem.target` and `NSToolbarItem.target` are both
    /// weak, so a helper that let the toolbar go out of scope would hand back an item whose target
    /// had already been zeroed, and the test would be asserting against the test's own lifetime
    /// rather than against the item.
    private func makeContentModeItem() -> (owner: MainWindowToolbar, item: NSToolbarItem) {
        let identifier = NSToolbar.Identifier("com.TablePro.tests.toolbar.\(UUID().uuidString)")
        let owner = MainWindowToolbar(managedToolbar: NSToolbar(identifier: identifier))
        return (owner, owner.makeContentModeItem(claimsSlot: true))
    }

    @Test("The mode item carries a menu form with one actionable item per mode")
    func menuFormOffersEveryMode() throws {
        let (owner, item) = makeContentModeItem()
        let submenu = try #require(item.menuFormRepresentation?.submenu)

        #expect(submenu.items.count == 2)
        #expect(submenu.items.map(\.title) == [
            MainWindowToolbar.contentModeLabel(.browse),
            MainWindowToolbar.contentModeLabel(.assistant)
        ])
        for menuItem in submenu.items {
            #expect(menuItem.action != nil)
            #expect(menuItem.target as? MainWindowToolbar === owner)
        }
    }

    /// The tag is what the action reads. Without it the sender says which item was clicked and not
    /// which segment it stands for, which is exactly why the menu was inert.
    @Test("Each menu item names its segment by tag, in the control's own order")
    func menuItemsCarryTheirSegmentIndex() throws {
        let (owner, item) = makeContentModeItem()
        let submenu = try #require(item.menuFormRepresentation?.submenu)

        #expect(submenu.items.map(\.tag) == [0, 1])
        withExtendedLifetime(owner) {}
    }

    @Test("The item is the segmented group the control needs, not a plain item")
    func itemIsAnExpandedGroup() throws {
        let (owner, item) = makeContentModeItem()
        let group = try #require(item as? NSToolbarItemGroup)

        #expect(group.selectionMode == .selectOne)
        #expect(group.controlRepresentation == .expanded)
        #expect(group.subitems.count == 2)
        withExtendedLifetime(owner) {}
    }

    /// VoiceOver takes an expanded group's segment names from each image's accessibility
    /// description, so a nil one leaves it reading the SF Symbol name.
    @Test("Every segment image is named for VoiceOver")
    func segmentImagesAreNamed() throws {
        let (owner, item) = makeContentModeItem()
        let group = try #require(item as? NSToolbarItemGroup)
        let descriptions = group.subitems.compactMap(\.image?.accessibilityDescription)

        #expect(descriptions == [
            MainWindowToolbar.contentModeLabel(.browse),
            MainWindowToolbar.contentModeLabel(.assistant)
        ])
        withExtendedLifetime(owner) {}
    }

    /// A Customize Toolbar palette copy is a second item for the same identifier, and it gets the
    /// same working menu form: it is what the user drags, and an inert copy would put a dead
    /// control back into the toolbar.
    @Test("A palette copy is its own item and carries the same menu form")
    func paletteCopyIsIndependentAndComplete() throws {
        let identifier = NSToolbar.Identifier("com.TablePro.tests.toolbar.\(UUID().uuidString)")
        let owner = MainWindowToolbar(managedToolbar: NSToolbar(identifier: identifier))
        let claimed = try #require(owner.makeContentModeItem(claimsSlot: true) as? NSToolbarItemGroup)
        let copy = try #require(owner.makeContentModeItem(claimsSlot: false) as? NSToolbarItemGroup)

        #expect(claimed !== copy)
        #expect(copy.menuFormRepresentation?.submenu?.items.map(\.tag) == [0, 1])
    }
}
