//
//  TabPersistenceGenerationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProEditorKit
import Testing

// A save that finds the generation unmoved returns before building anything, so every write a save reads has to move it.
@MainActor
struct TabPersistenceGenerationTests {
    private func makeFixture() -> (CoordinatorFixture, QueryTab, QueryTab) {
        let fixture = CoordinatorFixture()
        let first = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query))
        let second = fixture.addTab(QueryTab(title: "Query 2", query: "", tabType: .query), select: false)
        return (fixture, first, second)
    }

    private func moves(_ manager: QueryTabManager, _ change: () -> Void) -> Bool {
        let before = manager.persistenceGeneration
        change()
        return manager.persistenceGeneration != before
    }

    @Test("Typing that changes no tab fact still moves the generation")
    func editorTextMovesTheGeneration() {
        let (fixture, tab, _) = makeFixture()
        #expect(moves(fixture.tabManager) { _ = fixture.tabManager.setEditorText("SELECT 2", ofTab: tab.id) })
    }

    @Test("Selecting another tab moves the generation, selecting the same one does not")
    func selectionMovesTheGeneration() {
        let (fixture, _, other) = makeFixture()
        #expect(moves(fixture.tabManager) { fixture.tabManager.selectedTabId = other.id })
        #expect(!moves(fixture.tabManager) { fixture.tabManager.selectedTabId = other.id })
    }

    @Test("A sort written through the tab moves the generation")
    func sortMovesTheGeneration() {
        let (fixture, tab, _) = makeFixture()
        #expect(moves(fixture.tabManager) {
            fixture.tabManager.mutate(tabId: tab.id) {
                $0.sortState.columns = [SortColumn(columnIndex: 0, direction: .descending)]
            }
        })
    }

    @Test("Moving the caret moves the generation")
    func caretMovesTheGeneration() {
        let (fixture, _, _) = makeFixture()
        #expect(moves(fixture.tabManager) {
            fixture.coordinator.cursorPositions = [CursorPosition(range: NSRange(location: 3, length: 0))]
        })
    }

    @Test("A grid selection moves the generation, writing the same one does not")
    func gridSelectionMovesTheGeneration() throws {
        let (fixture, tab, _) = makeFixture()
        _ = fixture.coordinator.gridModel(forTab: tab.id)
        let store = try #require(fixture.coordinator.dataGridEntries[tab.id]?.store)
        var changed = store.selectionSnapshot
        changed.mode = .rows
        #expect(moves(fixture.tabManager) { store.selectionSnapshot = changed })
        #expect(!moves(fixture.tabManager) { store.selectionSnapshot = changed })
    }

    @Test("Each write reaches the owner's change-driven save")
    func writesReachTheOwner() {
        let (fixture, tab, other) = makeFixture()
        var reported = 0
        fixture.tabManager.onPersistedStateChange = { reported += 1 }
        _ = fixture.tabManager.setEditorText("SELECT 3", ofTab: tab.id)
        fixture.tabManager.selectedTabId = other.id
        #expect(reported == 2)
    }
}
