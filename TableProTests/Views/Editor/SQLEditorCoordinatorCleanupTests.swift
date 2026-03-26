//
//  SQLEditorCoordinatorCleanupTests.swift
//  TableProTests
//
//  Regression tests for SQLEditorCoordinator cleanup safety.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("SQLEditorCoordinator Cleanup")
struct SQLEditorCoordinatorCleanupTests {
    @Test("destroy() on fresh coordinator does not crash")
    func destroyWithoutInstall() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("destroy() called twice is idempotent")
    func destroyTwiceIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("After destroy(), vimMode is .normal")
    func postDestroyVimMode() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("Callbacks can be set before install")
    func callbacksBeforeInstall() {
        let coordinator = SQLEditorCoordinator()
        coordinator.onCloseTab = {}
        coordinator.onExecuteQuery = {}
        coordinator.onAIExplain = { _ in }
        coordinator.destroy()
    }
}
