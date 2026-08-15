//
//  MainWindowToolbarLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct MainWindowToolbarLayoutTests {
    @Test("Sidebar toggle is ordered into the sidebar's titlebar strip")
    func sidebarToggleOrderedBeforeTrackingSeparator() throws {
        let identifiers = MainWindowToolbar.defaultItemIdentifiers
        let toggleIndex = try #require(identifiers.firstIndex(of: MainWindowToolbar.sidebarToggle))
        let separatorIndex = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(toggleIndex < separatorIndex)
    }

    @Test("Sidebar toggle is not navigational")
    func sidebarToggleIsNotNavigational() {
        let group = MainWindowToolbar.makeSidebarSegmentGroup(target: nil, action: #selector(NSView.layout))
        #expect(group.isNavigational == false)
    }

    @Test("Sidebar toggle stays an expanded one-of-two segmented control")
    func sidebarToggleIsExpandedSegmentedControl() {
        let group = MainWindowToolbar.makeSidebarSegmentGroup(target: nil, action: #selector(NSView.layout))
        #expect(group.controlRepresentation == .expanded)
        #expect(group.selectionMode == .selectOne)
        #expect(group.subitems.count == 2)
    }
}

@MainActor
struct MainWindowToolbarCustomizationTests {
    /// Opening Customize Toolbar makes AppKit ask the delegate again, with the flag off, for the
    /// palette copies. Those used to overwrite the retained hosting controllers, releasing the ones
    /// whose views were on screen, and the connection group and status item collapsed to nothing.
    @Test("Only the item going into the toolbar claims the retained controller")
    func paletteCopiesDoNotClaimTheSlot() {
        #expect(MainWindowToolbar.retainsHostingController(willBeInsertedIntoToolbar: true))
        #expect(!MainWindowToolbar.retainsHostingController(willBeInsertedIntoToolbar: false))
    }

    /// The identifier is the autosave name. Changing it silently discards every user's arrangement,
    /// which is what the v1 to v2 move already cost once.
    @Test("The toolbar identifier is stable")
    func identifierIsStable() {
        #expect(MainWindowToolbar.toolbarIdentifier == "com.TablePro.main.toolbar.v2")
    }
}

@MainActor
struct MainWindowToolbarHostedSizingTests {
    private static let hostedIdentifiers: [NSToolbarItem.Identifier] = [
        MainWindowToolbar.connectionGroup,
        MainWindowToolbar.principal,
    ]

    private func vendHostedItems() -> MainWindowToolbar {
        let owner = MainWindowToolbar()
        for identifier in Self.hostedIdentifiers {
            _ = owner.toolbar(
                owner.managedToolbar,
                itemForItemIdentifier: identifier,
                willBeInsertedIntoToolbar: true
            )
        }
        return owner
    }

    /// AppKit measures a view-backed item when it is inserted and never reads that size again, so
    /// the hosting view has to resize itself. Under `.intrinsicContentSize` it does not, and the
    /// leading group kept the width of the connection the window had switched away from until the
    /// user clicked the toolbar.
    @Test("Hosted toolbar items size themselves from the preferred content size")
    func hostedItemsSizeFromPreferredContentSize() throws {
        let owner = vendHostedItems()
        for identifier in Self.hostedIdentifiers {
            let controller = try #require(owner.hostingControllers[identifier])
            #expect(controller.sizingOptions == .preferredContentSize, "\(identifier.rawValue)")
        }
    }

    /// Measured on macOS 27: `[.minSize, .intrinsicContentSize, .maxSize]` shrinks the hosted
    /// content but leaves AppKit's item container at the old width, drawing the new content
    /// centred inside the old box. That is the artifact this suite exists to keep out.
    @Test("Hosted toolbar items never size from the intrinsic content size")
    func hostedItemsNeverSizeFromIntrinsicContentSize() throws {
        let owner = vendHostedItems()
        for identifier in Self.hostedIdentifiers {
            let controller = try #require(owner.hostingControllers[identifier])
            #expect(!controller.sizingOptions.contains(.intrinsicContentSize), "\(identifier.rawValue)")
        }
    }

    /// Both hosted items are built through the same two helpers, so the contract belongs to the
    /// helpers rather than to either call site.
    @Test("Every hosted item shares one sizing contract")
    func hostedItemsShareOneSizingContract() {
        #expect(MainWindowToolbar.hostedItemSizingOptions == .preferredContentSize)
    }
}
