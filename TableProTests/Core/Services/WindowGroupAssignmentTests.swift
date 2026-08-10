//
//  WindowGroupAssignmentTests.swift
//  TableProTests
//
//  Every window of a connection restores at the same time, in no defined order, so the rule deciding
//  which tabs are whose has to depend only on the window's own position. A connection with more than
//  one window open used to come back with every window empty, because each one stood down on seeing a
//  sibling and none of them claimed the tabs.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Window group assignment")
struct WindowGroupAssignmentTests {
    private func tab(_ title: String) -> QueryTab {
        QueryTab(id: UUID(), title: title, query: "SELECT 1", tabType: .table)
    }

    private func indices(_ pairs: [(QueryTab, Int)]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
    }

    @Test("A window claims the group saved at its own position")
    func claimsOwnGroup() {
        let first = tab("First")
        let second = tab("Second")
        let third = tab("Third")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 1,
            openWindowCount: 3,
            tabs: [first, second, third],
            windowGroupIndexByTabId: indices([(first, 0), (second, 1), (third, 2)]),
            selectedTabId: nil
        )

        #expect(plan.ownTabs == [second])
        #expect(plan.orphanedGroups.isEmpty)
    }

    /// The property that lets every window decide alone: only the leftmost one reopens anything, so
    /// two windows can never both restore the same saved group into a window of their own.
    @Test("Only the leftmost window reports orphaned groups")
    func onlyLeftmostWindowFansOut() {
        let kept = tab("Kept")
        let orphaned = tab("Orphaned")
        let byId = indices([(kept, 0), (orphaned, 4)])

        let leftmost = WindowGroupAssignment.resolve(
            windowIndex: 0,
            openWindowCount: 2,
            tabs: [kept, orphaned],
            windowGroupIndexByTabId: byId,
            selectedTabId: nil
        )
        let other = WindowGroupAssignment.resolve(
            windowIndex: 1,
            openWindowCount: 2,
            tabs: [kept, orphaned],
            windowGroupIndexByTabId: byId,
            selectedTabId: nil
        )

        #expect(leftmost.orphanedGroups.map(\.windowGroupIndex) == [4])
        #expect(other.orphanedGroups.isEmpty)
    }

    @Test("A group that still has a window is never reopened")
    func liveWindowsAreNotFannedOut() {
        let first = tab("First")
        let second = tab("Second")
        let third = tab("Third")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 0,
            openWindowCount: 3,
            tabs: [first, second, third],
            windowGroupIndexByTabId: indices([(first, 0), (second, 1), (third, 2)]),
            selectedTabId: nil
        )

        #expect(plan.ownTabs == [first])
        #expect(plan.orphanedGroups.isEmpty)
    }

    @Test("Orphaned groups come back in saved order")
    func orphanedGroupsAreOrdered() {
        let kept = tab("Kept")
        let later = tab("Later")
        let earlier = tab("Earlier")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 0,
            openWindowCount: 1,
            tabs: [kept, later, earlier],
            windowGroupIndexByTabId: indices([(kept, 0), (later, 3), (earlier, 1)]),
            selectedTabId: nil
        )

        #expect(plan.orphanedGroups.map(\.windowGroupIndex) == [1, 3])
    }

    /// A window that was blank when the session ended comes back blank, rather than being handed
    /// somebody else's tab.
    @Test("A window with nothing saved at its position stays empty")
    func windowWithoutSavedGroupStaysEmpty() {
        let first = tab("First")
        let third = tab("Third")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 1,
            openWindowCount: 3,
            tabs: [first, third],
            windowGroupIndexByTabId: indices([(first, 0), (third, 2)]),
            selectedTabId: nil
        )

        #expect(plan.ownTabs.isEmpty)
        #expect(plan.orphanedGroups.isEmpty)
    }

    @Test("A window that held several tabs gets all of them back")
    func multipleTabsInOneWindow() {
        let left = tab("Left")
        let right = tab("Right")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 0,
            openWindowCount: 1,
            tabs: [left, right],
            windowGroupIndexByTabId: indices([(left, 0), (right, 0)]),
            selectedTabId: right.id
        )

        #expect(plan.ownTabs == [left, right])
        #expect(plan.ownSelectedTabId == right.id)
    }

    @Test("The selected tab is only reported by the group that holds it")
    func selectionBelongsToOneGroup() {
        let kept = tab("Kept")
        let orphaned = tab("Orphaned")

        let plan = WindowGroupAssignment.resolve(
            windowIndex: 0,
            openWindowCount: 1,
            tabs: [kept, orphaned],
            windowGroupIndexByTabId: indices([(kept, 0), (orphaned, 1)]),
            selectedTabId: orphaned.id
        )

        #expect(plan.ownSelectedTabId == nil)
        #expect(plan.orphanedGroups.first?.selectedTabId == orphaned.id)
    }

    /// A file written before tabs recorded their window has no grouping at all. Reading every tab as
    /// window zero would pile them into one window, and with no in-window tab bar all but one would be
    /// invisible, so each tab keeps a window of its own exactly as it always has.
    @Test("A file saved without window positions gives each tab its own window")
    func legacyFileKeepsOneTabPerWindow() {
        let first = PersistedTab(id: UUID(), title: "First", query: "SELECT 1", tabType: .table, tableName: nil)
        let second = PersistedTab(id: UUID(), title: "Second", query: "SELECT 2", tabType: .table, tableName: nil)

        let normalized = WindowGroupAssignment.normalizedGroupIndices(for: [first, second])

        #expect(normalized[first.id] == 0)
        #expect(normalized[second.id] == 1)
    }

    @Test("A file that records window positions keeps them")
    func recordedPositionsAreKept() {
        let first = PersistedTab(
            id: UUID(), title: "First", query: "SELECT 1", tabType: .table, tableName: nil, windowGroupIndex: 2
        )
        let second = PersistedTab(
            id: UUID(), title: "Second", query: "SELECT 2", tabType: .table, tableName: nil, windowGroupIndex: 0
        )

        let normalized = WindowGroupAssignment.normalizedGroupIndices(for: [first, second])

        #expect(normalized[first.id] == 2)
        #expect(normalized[second.id] == 0)
    }
}
