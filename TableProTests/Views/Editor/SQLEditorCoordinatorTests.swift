//
//  SQLEditorCoordinatorTests.swift
//  TableProTests
//
//  Tests for SQLEditorCoordinator destroy() lifecycle.
//

import Foundation
import TableProPluginKit
@testable import TablePro
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
}
