//
//  SQLEditorCoordinatorTests.swift
//  TableProTests
//
//  Tests for SQLEditorCoordinator destroy() lifecycle.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("SQLEditorCoordinator")
struct SQLEditorCoordinatorTests {
    @Test("Initial isDestroyed is false")
    func initialIsDestroyedIsFalse() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.isDestroyed == false)
    }

    @Test("destroy() sets isDestroyed to true")
    func destroySetsIsDestroyedTrue() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() can be called multiple times safely")
    func destroyIsIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.isDestroyed == true)
    }

    @Test("destroy() resets vimMode to .normal")
    func destroyResetsVimMode() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("pendingFocusClaim starts false on a fresh coordinator")
    func freshCoordinatorHasNoPendingClaim() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.pendingFocusClaim == false)
    }

    @Test("scheduleEditorFocusClaim() sets pendingFocusClaim to true")
    func scheduleEditorFocusClaimSetsLatch() {
        let coordinator = SQLEditorCoordinator()
        coordinator.scheduleEditorFocusClaim()
        #expect(coordinator.pendingFocusClaim == true)
    }

    @Test("scheduleEditorFocusClaim() is idempotent")
    func scheduleEditorFocusClaimIsIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.scheduleEditorFocusClaim()
        coordinator.scheduleEditorFocusClaim()
        #expect(coordinator.pendingFocusClaim == true)
    }
}
