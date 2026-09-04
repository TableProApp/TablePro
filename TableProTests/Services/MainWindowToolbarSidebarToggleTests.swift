//
//  MainWindowToolbarSidebarToggleTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// The sidebar toggle had both defects the mode control was fixed for, on the control beside it.
///
/// Its segment images carried no `accessibilityDescription`, so VoiceOver read the SF Symbol names
/// and the control announced itself as "List" and "favorite"; and its action could only read a
/// selection off an `NSToolbarItemGroup`, so choosing Tables or Favorites from the toolbar's
/// overflow menu did nothing at all.
@MainActor
struct MainWindowToolbarSidebarToggleTests {
    /// The owner comes back with the item, because `NSMenuItem.target` and `NSToolbarItem.target`
    /// are both weak and a helper that dropped the toolbar would hand back a zeroed target.
    private func makeSidebarItem() -> (owner: MainWindowToolbar, item: NSToolbarItem) {
        let identifier = NSToolbar.Identifier("com.TablePro.tests.toolbar.\(UUID().uuidString)")
        let owner = MainWindowToolbar(managedToolbar: NSToolbar(identifier: identifier))
        return (owner, owner.makeSidebarToggleItem(claimsSlot: true))
    }

    @Test("Every segment image is named, so VoiceOver does not read the SF Symbol")
    func segmentImagesAreNamed() throws {
        let (owner, item) = makeSidebarItem()
        let group = try #require(item as? NSToolbarItemGroup)
        let descriptions = group.subitems.compactMap(\.image?.accessibilityDescription)

        #expect(descriptions == [
            MainWindowToolbar.sidebarSegmentLabel(.tables),
            MainWindowToolbar.sidebarSegmentLabel(.favorites)
        ])
        #expect(!descriptions.contains("list.bullet"))
        #expect(!descriptions.contains("star"))
        withExtendedLifetime(owner) {}
    }

    @Test("The overflow menu offers one actionable item per tab")
    func menuFormOffersEveryTab() throws {
        let (owner, item) = makeSidebarItem()
        let submenu = try #require(item.menuFormRepresentation?.submenu)

        #expect(submenu.items.map(\.title) == [
            MainWindowToolbar.sidebarSegmentLabel(.tables),
            MainWindowToolbar.sidebarSegmentLabel(.favorites)
        ])
        for menuItem in submenu.items {
            #expect(menuItem.action != nil)
            #expect(menuItem.target as? MainWindowToolbar === owner)
        }
    }

    /// The tag is what the action reads from a menu item. Without it the sender names which item was
    /// clicked and not which segment it stands for, which is why the menu was inert.
    @Test("Each menu item names its segment by tag, in the control's own order")
    func menuItemsCarryTheirSegmentIndex() throws {
        let (owner, item) = makeSidebarItem()
        let submenu = try #require(item.menuFormRepresentation?.submenu)

        #expect(submenu.items.map(\.tag) == [0, 1])
        withExtendedLifetime(owner) {}
    }

    @Test("The item is the segmented group the control needs")
    func itemIsAnExpandedGroup() throws {
        let (owner, item) = makeSidebarItem()
        let group = try #require(item as? NSToolbarItemGroup)

        #expect(group.selectionMode == .selectOne)
        #expect(group.subitems.count == 2)
        withExtendedLifetime(owner) {}
    }
}
