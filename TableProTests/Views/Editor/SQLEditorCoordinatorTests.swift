//
//  SQLEditorCoordinatorTests.swift
//  TableProTests
//
//  Tests for SQLEditorCoordinator lifecycle.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("SQLEditorCoordinator")
struct SQLEditorCoordinatorTests {
    @Test("Fresh coordinator vimMode is .normal")
    func initialVimMode() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("destroy() can be called without install")
    func destroyWithoutInstall() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }

    @Test("destroy() is idempotent")
    func destroyIdempotent() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        coordinator.destroy()
        coordinator.destroy()
        #expect(coordinator.vimMode == .normal)
    }
}
