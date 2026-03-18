//
//  SQLEditorCoordinatorCleanupTests.swift
//  TableProTests
//
//  Regression tests for SQLEditorCoordinator cleanup consolidation (P2-12).
//  Validates that destroy() and monitor cleanup are safe and idempotent.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("SQLEditorCoordinator Cleanup")
struct SQLEditorCoordinatorCleanupTests {
    // MARK: - destroy() Safety

    @Test("destroy() on fresh coordinator without prepareCoordinator does not crash")
    func destroyWithoutPrepare() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() called twice is idempotent and does not crash")
    func destroyTwiceIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() called three times remains safe")
    func destroyTripleCall() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
        #expect(coordinator.vimMode == .normal)
    }

    // MARK: - Post-Destroy State

    @Test("After destroy(), vimMode is .normal")
    func postDestroyVimMode() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("After destroy(), isEditorFirstResponder returns false")
    func postDestroyFirstResponder() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.isEditorFirstResponder == false)
    }

    @Test("After destroy(), controller is nil (never set)")
    func postDestroyControllerNil() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.controller == nil)
    }

    // MARK: - Initial State

    @Test("Fresh coordinator isDestroyed is false")
    func freshCoordinatorNotDestroyed() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.isDestroyed == false)
    }

    @Test("Fresh coordinator vimMode is .normal")
    func freshCoordinatorVimModeNormal() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("Fresh coordinator has no controller")
    func freshCoordinatorNoController() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.controller == nil)
    }
}
