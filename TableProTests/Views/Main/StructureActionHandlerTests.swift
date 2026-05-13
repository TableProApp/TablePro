//
//  StructureActionHandlerTests.swift
//  TableProTests
//
//  Tests for StructureViewActionHandler closure dispatch and coordinator integration.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor @Suite("StructureViewActionHandler")
struct StructureActionHandlerTests {
    // MARK: - Helpers

    private func makeCoordinator() -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        return state.coordinator
    }

    // MARK: - Individual Closure Dispatch

    @Test("saveChanges closure fires when invoked")
    func saveChanges_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.saveChanges = { count += 1 }

        handler.saveChanges?()

        #expect(count == 1)
    }

    @Test("previewSQL closure fires when invoked")
    func previewSQL_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.previewSQL = { count += 1 }

        handler.previewSQL?()

        #expect(count == 1)
    }

    @Test("copyRows closure fires when invoked")
    func copyRows_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.copyRows = { count += 1 }

        handler.copyRows?()

        #expect(count == 1)
    }

    @Test("pasteRows closure fires when invoked")
    func pasteRows_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.pasteRows = { count += 1 }

        handler.pasteRows?()

        #expect(count == 1)
    }

    @Test("undo closure fires when invoked")
    func undo_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.undo = { count += 1 }

        handler.undo?()

        #expect(count == 1)
    }

    @Test("redo closure fires when invoked")
    func redo_fires() {
        let handler = StructureViewActionHandler()
        var count = 0
        handler.redo = { count += 1 }

        handler.redo?()

        #expect(count == 1)
    }

    // MARK: - All Six Closures Fire Independently

    @Test("all six closures fire independently without cross-talk")
    func allClosures_fireIndependently() {
        let handler = StructureViewActionHandler()
        var counts = [String: Int]()

        handler.saveChanges = { counts["saveChanges", default: 0] += 1 }
        handler.previewSQL = { counts["previewSQL", default: 0] += 1 }
        handler.copyRows = { counts["copyRows", default: 0] += 1 }
        handler.pasteRows = { counts["pasteRows", default: 0] += 1 }
        handler.undo = { counts["undo", default: 0] += 1 }
        handler.redo = { counts["redo", default: 0] += 1 }

        handler.saveChanges?()
        handler.previewSQL?()
        handler.copyRows?()
        handler.pasteRows?()
        handler.undo?()
        handler.redo?()

        #expect(counts["saveChanges"] == 1)
        #expect(counts["previewSQL"] == 1)
        #expect(counts["copyRows"] == 1)
        #expect(counts["pasteRows"] == 1)
        #expect(counts["undo"] == 1)
        #expect(counts["redo"] == 1)
    }

    // MARK: - Nil Closures Are Safe

    @Test("nil closures do not crash via optional chaining")
    func nilClosures_areSafe() {
        let handler = StructureViewActionHandler()

        // All closures are nil by default; optional chaining should be a no-op
        handler.saveChanges?()
        handler.previewSQL?()
        handler.copyRows?()
        handler.pasteRows?()
        handler.undo?()
        handler.redo?()

        // Reaching here without a crash is the assertion
    }

    // MARK: - Coordinator Integration

    @Test("coordinator.structureActions dispatches saveChanges closure")
    func coordinator_dispatchesSaveChanges() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let handler = StructureViewActionHandler()
        var count = 0
        handler.saveChanges = { count += 1 }
        coordinator.structureActions = handler

        coordinator.structureActions?.saveChanges?()

        #expect(count == 1)
    }

    @Test("coordinator.structureActions dispatches all closures")
    func coordinator_dispatchesAllClosures() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let handler = StructureViewActionHandler()
        var counts = [String: Int]()

        handler.saveChanges = { counts["saveChanges", default: 0] += 1 }
        handler.previewSQL = { counts["previewSQL", default: 0] += 1 }
        handler.copyRows = { counts["copyRows", default: 0] += 1 }
        handler.pasteRows = { counts["pasteRows", default: 0] += 1 }
        handler.undo = { counts["undo", default: 0] += 1 }
        handler.redo = { counts["redo", default: 0] += 1 }

        coordinator.structureActions = handler

        coordinator.structureActions?.saveChanges?()
        coordinator.structureActions?.previewSQL?()
        coordinator.structureActions?.copyRows?()
        coordinator.structureActions?.pasteRows?()
        coordinator.structureActions?.undo?()
        coordinator.structureActions?.redo?()

        #expect(counts["saveChanges"] == 1)
        #expect(counts["previewSQL"] == 1)
        #expect(counts["copyRows"] == 1)
        #expect(counts["pasteRows"] == 1)
        #expect(counts["undo"] == 1)
        #expect(counts["redo"] == 1)
    }

    // MARK: - Weak Reference Nil-Out

    @Test("closures no longer fire after coordinator.structureActions is set to nil")
    func coordinatorNilOut_closuresNoLongerFire() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let handler = StructureViewActionHandler()
        var count = 0
        handler.saveChanges = { count += 1 }
        coordinator.structureActions = handler

        // Verify it works before nil-out
        coordinator.structureActions?.saveChanges?()
        #expect(count == 1)

        // Nil out the weak reference
        coordinator.structureActions = nil

        // Calling through coordinator should be a no-op now
        coordinator.structureActions?.saveChanges?()
        #expect(count == 1)
    }
}
