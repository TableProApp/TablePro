//
//  SidebarSearchPersistenceTests.swift
//  TableProTests
//
//  Regression guard for #1690 where opening a table from a filtered sidebar
//  cleared the active filter. searchFieldDidEndSearching fired on focus loss
//  and wrote "" back over the persisted filter text. The filter must only be
//  cleared when the field is actually empty (cancel button / explicit clear).
//

import Foundation
import Testing

@testable import TablePro

@Suite("Sidebar search persistence on end editing")
struct SidebarSearchPersistenceTests {
    @Test("keeps the filter when the field still has text and focus is lost")
    func keepsFilterWhenFieldHasText() {
        #expect(!SidebarContainerViewController.shouldClearOnEndSearching(fieldValue: "dp_"))
    }

    @Test("clears the filter when the field is empty")
    func clearsFilterWhenFieldEmpty() {
        #expect(SidebarContainerViewController.shouldClearOnEndSearching(fieldValue: ""))
    }
}
