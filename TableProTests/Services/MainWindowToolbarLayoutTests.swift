//
//  MainWindowToolbarLayoutTests.swift
//  TableProTests
//

import AppKit
import Foundation
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
