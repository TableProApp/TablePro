//
//  QueryTabReorderTests.swift
//  TableProTests
//
//  Editor tabs could not be reordered at all. Before #2097 they were windows, so AppKit's own tab
//  bar reordered them for free; when they became a drawn strip, nothing replaced that.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("Query tab reordering")
struct QueryTabReorderTests {
    private func makeManager(_ count: Int) -> QueryTabManager {
        let manager = QueryTabManager()
        for index in 0 ..< count {
            manager.tabs.append(QueryTab(title: "tab\(index)", query: "", tabType: .query))
        }
        manager.selectedTabId = manager.tabs.first?.id
        return manager
    }

    private func titles(_ manager: QueryTabManager) -> [String] {
        manager.tabs.map(\.title)
    }

    @Test("A tab moves to the position it was dropped on")
    func movesToDestination() {
        let manager = makeManager(4)
        let moving = manager.tabs[0].id

        manager.moveTab(id: moving, to: 2)

        #expect(titles(manager) == ["tab1", "tab2", "tab0", "tab3"])
    }

    @Test("A tab dragged left lands before the tab it passed")
    func movesLeft() {
        let manager = makeManager(4)
        manager.moveTab(id: manager.tabs[3].id, to: 1)
        #expect(titles(manager) == ["tab0", "tab3", "tab1", "tab2"])
    }

    /// The selection follows the tab, not the slot. Dragging the tab you are looking at must not
    /// switch you to whatever slides into the place it left.
    @Test("Reordering keeps the selection on the same tab")
    func selectionFollowsTheTab() {
        let manager = makeManager(4)
        let selected = manager.tabs[1].id
        manager.selectedTabId = selected

        manager.moveTab(id: selected, to: 3)

        #expect(manager.selectedTabId == selected)
        #expect(manager.tabs[3].id == selected)
    }

    @Test("A destination outside the strip is clamped rather than trapping")
    func clampsOutOfRangeDestinations() {
        let manager = makeManager(3)
        let first = manager.tabs[0].id

        manager.moveTab(id: first, to: 99)
        #expect(manager.tabs.last?.id == first)

        manager.moveTab(id: first, to: -5)
        #expect(manager.tabs.first?.id == first)
        #expect(manager.tabs.count == 3)
    }

    @Test("Moving a tab onto its own position changes nothing")
    func noOpOnSamePosition() {
        let manager = makeManager(3)
        let before = titles(manager)
        let version = manager.tabStructureVersion

        manager.moveTab(id: manager.tabs[1].id, to: 1)

        #expect(titles(manager) == before)
        #expect(manager.tabStructureVersion == version)
    }

    @Test("Moving a tab that is not in the strip changes nothing")
    func ignoresUnknownTab() {
        let manager = makeManager(3)
        let before = titles(manager)

        manager.moveTab(id: UUID(), to: 0)

        #expect(titles(manager) == before)
    }

    /// `tabs.didSet` republishes workspace anchors and bumps the structure version on every write,
    /// so the reorder assigns the finished array once instead of removing and inserting in place.
    @Test("A reorder is one structural change, not two")
    func reorderBumpsTheStructureVersionOnce() {
        let manager = makeManager(4)
        let version = manager.tabStructureVersion

        manager.moveTab(id: manager.tabs[0].id, to: 3)

        #expect(manager.tabStructureVersion == version + 1)
    }

    @Test("The edges of the strip know they cannot move further out")
    func edgeTabsReportTheirLimits() {
        let manager = makeManager(3)

        #expect(!manager.canMoveTab(id: manager.tabs[0].id, by: -1))
        #expect(manager.canMoveTab(id: manager.tabs[0].id, by: 1))
        #expect(manager.canMoveTab(id: manager.tabs[2].id, by: -1))
        #expect(!manager.canMoveTab(id: manager.tabs[2].id, by: 1))
        #expect(!manager.canMoveTab(id: UUID(), by: 1))
    }

    @Test("Move Tab Left and Move Tab Right shift by one")
    func movesByOffset() {
        let manager = makeManager(3)
        let middle = manager.tabs[1].id

        manager.moveTab(id: middle, by: -1)
        #expect(manager.tabs[0].id == middle)

        manager.moveTab(id: middle, by: 1)
        #expect(manager.tabs[1].id == middle)
    }

    /// A single tab has nowhere to go, and the offset form must not walk off the end.
    @Test("A lone tab cannot be moved")
    func loneTabStaysPut() {
        let manager = makeManager(1)
        let only = manager.tabs[0].id

        manager.moveTab(id: only, by: -1)
        manager.moveTab(id: only, by: 1)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].id == only)
    }
}
