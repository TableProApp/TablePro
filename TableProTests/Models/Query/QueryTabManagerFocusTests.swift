//
//  QueryTabManagerFocusTests.swift
//  TableProTests
//
//  Locks the contract for pendingFocusTabId, the one-shot signal that tells
//  the editor view layer a newly created query tab should claim keyboard focus.
//  Only addTab(claimFocus:) sets it; tab restoration and table tabs never do.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("QueryTabManager editor focus claim")
@MainActor
struct QueryTabManagerFocusTests {
    @Test("addTab with claimFocus sets pendingFocusTabId to the new tab")
    func addTabWithClaimFocusSetsPendingId() {
        let manager = QueryTabManager()
        manager.addTab(claimFocus: true)
        #expect(manager.pendingFocusTabId == manager.tabs.last?.id)
    }

    @Test("addTab without claimFocus leaves pendingFocusTabId nil")
    func addTabWithoutClaimFocusLeavesNil() {
        let manager = QueryTabManager()
        manager.addTab()
        #expect(manager.pendingFocusTabId == nil)
    }

    @Test("second addTab with claimFocus updates pendingFocusTabId to the latest tab")
    func secondAddTabWithClaimFocusUpdatesToLatest() {
        let manager = QueryTabManager()
        manager.addTab(claimFocus: true)
        manager.addTab(claimFocus: true)
        #expect(manager.pendingFocusTabId == manager.tabs.last?.id)
    }

    @Test("opening a new file-backed tab with claimFocus sets pendingFocusTabId")
    func newFileTabWithClaimFocusSetsPendingId() {
        let manager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/tablepro-focus-new.sql")
        manager.addTab(initialQuery: "SELECT 1", sourceFileURL: url, claimFocus: true)
        #expect(manager.pendingFocusTabId == manager.tabs.last?.id)
    }

    @Test("reopening an existing file tab does not set pendingFocusTabId")
    func fileURLDeduplicationDoesNotSetFocusId() {
        let manager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/tablepro-focus-test.sql")
        manager.addTab(sourceFileURL: url, claimFocus: true)
        manager.pendingFocusTabId = nil
        manager.addTab(sourceFileURL: url, claimFocus: true)
        #expect(manager.pendingFocusTabId == nil)
    }

    @Test("addTableTab does not set pendingFocusTabId")
    func addTableTabDoesNotSetFocusId() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        #expect(manager.pendingFocusTabId == nil)
    }
}
