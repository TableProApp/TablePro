//
//  ValueFilterChangeGuardTests.swift
//  TableProTests
//
//  A pending cell edit is recorded against a display row, so anything that changes which row a
//  position names re-points it. Sort, pagination and the WHERE filter already confirm before doing
//  that; the per-column value filter did not. (#2667)
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class GuardPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// Holds the work instead of running it, standing in for a reader who has not answered the alert.
@MainActor
private final class DeferringDelegate: DataGridViewDelegate {
    private(set) var askedCount = 0
    private var pending: (() -> Void)?

    func dataGridConfirmDisplayOrderChange(then apply: @escaping () -> Void) {
        askedCount += 1
        pending = apply
    }

    func confirm() {
        let work = pending
        pending = nil
        work?()
    }

    func discard() {
        pending = nil
    }
}

@Suite("Value filter change guard")
@MainActor
struct ValueFilterChangeGuardTests {
    private func makeCoordinator(delegate: (any DataGridViewDelegate)? = nil) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: GuardPersister()
        )
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.text("active"), .text("a")]),
            Row(id: .existing(1), values: [.text("inactive"), .text("b")]),
            Row(id: .existing(2), values: [.text("active"), .text("c")]),
        ]
        var captured = TableRows(
            rows: rows,
            columns: ["status", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { mutation in mutation(&captured) }
        coordinator.updateCache()
        return coordinator
    }

    private func onlyActive() -> ColumnValueFilter {
        ColumnValueFilter(selectedValues: ["active"], includesNull: false)
    }

    /// The structure, create-table and inspector grids own no pending edits and take the protocol
    /// default, so they must keep applying a filter with no round trip at all.
    @Test("a grid with no owner applies its filter directly")
    func ownerlessGridAppliesImmediately() {
        let coordinator = makeCoordinator()

        coordinator.applyValueFilter(onlyActive(), columnName: "status", forColumn: 0)

        #expect(coordinator.valueFilterState.isActive)
        #expect(coordinator.valueFilteredIDs?.count == 2)
    }

    @Test("a grid with an owner asks before it narrows anything")
    func ownedGridAsksFirst() {
        let delegate = DeferringDelegate()
        let coordinator = makeCoordinator(delegate: delegate)

        coordinator.applyValueFilter(onlyActive(), columnName: "status", forColumn: 0)

        #expect(delegate.askedCount == 1)
        /// Nothing moved yet. The filter is written inside the approved work, not before it, or the
        /// reader would be answering an alert about a change that had already happened.
        #expect(!coordinator.valueFilterState.isActive)
        #expect(coordinator.valueFilteredIDs == nil)
    }

    @Test("approving the change applies the filter")
    func approvingApplies() {
        let delegate = DeferringDelegate()
        let coordinator = makeCoordinator(delegate: delegate)
        coordinator.applyValueFilter(onlyActive(), columnName: "status", forColumn: 0)

        delegate.confirm()

        #expect(coordinator.valueFilterState.isActive)
        #expect(coordinator.valueFilteredIDs?.count == 2)
    }

    @Test("declining the change leaves the rows as they were")
    func decliningLeavesRowsAlone() {
        let delegate = DeferringDelegate()
        let coordinator = makeCoordinator(delegate: delegate)

        coordinator.applyValueFilter(onlyActive(), columnName: "status", forColumn: 0)
        delegate.discard()

        #expect(!coordinator.valueFilterState.isActive)
        #expect(coordinator.valueFilteredIDs == nil)
    }

    @Test("clearing every filter asks as well")
    func clearingAsksFirst() {
        let delegate = DeferringDelegate()
        let coordinator = makeCoordinator(delegate: delegate)
        coordinator.applyValueFilter(onlyActive(), columnName: "status", forColumn: 0)
        delegate.confirm()
        #expect(coordinator.valueFilterState.isActive)

        coordinator.clearAllValueFilters()
        #expect(delegate.askedCount == 2)
        #expect(coordinator.valueFilterState.isActive)

        delegate.confirm()
        #expect(!coordinator.valueFilterState.isActive)
    }

    @Test("clearing when nothing is filtered asks nothing")
    func clearingWithNoFilterAsksNothing() {
        let delegate = DeferringDelegate()
        let coordinator = makeCoordinator(delegate: delegate)

        coordinator.clearAllValueFilters()

        #expect(delegate.askedCount == 0)
    }
}
