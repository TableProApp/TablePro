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
