//
//  SQLEditorCoordinatorEscapeMenuTests.swift
//  TableProTests
//
//  Tests for SQLEditorCoordinator.handleEscapeFromMenu() routing.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("SQLEditorCoordinator menu escape")
struct SQLEditorCoordinatorEscapeMenuTests {
    @Test("handleEscapeFromMenu returns false when no editor is focused")
    func returnsFalseWhenNothingToHandle() {
        let coordinator = SQLEditorCoordinator()
        #expect(coordinator.handleEscapeFromMenu() == false)
    }

    @Test("handleEscapeFromMenu stays false after destroy so the grid keeps Escape")
    func staysFalseAfterDestroy() {
        let coordinator = SQLEditorCoordinator()
        coordinator.destroy()
        #expect(coordinator.handleEscapeFromMenu() == false)
    }
}
