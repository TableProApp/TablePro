//
//  TabFilterState+Editing.swift
//  TablePro
//

import Foundation
import SwiftUI

internal extension TabFilterState {
    enum FilterMoveDirection {
        case up
        case down
    }

    struct FilterMove: Equatable {
        let source: IndexSet
        let destination: Int
    }

    enum RemoveFilterOutcome: Equatable {
        case noChange
        case clear
        case reapply([TableFilter])
    }

    static func newFilter(
        settings: FilterSettings,
        columns: [String],
        primaryKeyColumn: String?,
        offersRawFilter: Bool
    ) -> TableFilter {
        let filterOperator = settings.defaultOperator.toFilterOperator()
        if settings.defaultColumn == .rawSQL, offersRawFilter {
            return .rawCondition("", filterOperator: filterOperator)
        }
        return TableFilter(
            columnName: settings.defaultColumn.columnName(
                columns: columns,
                primaryKeyColumn: primaryKeyColumn,
                offersRawFilter: offersRawFilter
            ),
            filterOperator: filterOperator
        )
    }

    @discardableResult
    mutating func addFilter(
        settings: FilterSettings,
        columns: [String],
        primaryKeyColumn: String?,
        offersRawFilter: Bool
    ) -> UUID {
        let filter = Self.newFilter(
            settings: settings,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            offersRawFilter: offersRawFilter
        )
        filters.append(filter)
        return filter.id
    }

    /// The row the panel opens with. A replaceable one is remembered as it was added, so a filter
    /// brought in from outside the panel takes its place until the reader edits it.
    @discardableResult
    mutating func addStartingFilter(
        settings: FilterSettings,
        columns: [String],
        primaryKeyColumn: String?,
        offersRawFilter: Bool,
        isReplaceable: Bool
    ) -> UUID {
        let id = addFilter(
            settings: settings,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            offersRawFilter: offersRawFilter
        )
        startingFilter = isReplaceable ? filters.last : nil
        return id
    }

    /// The panel's starting row only stood in for a condition, so it goes once one arrives from
    /// outside the panel. A row the reader changed is theirs and stays.
    mutating func dropUntouchedStartingFilter() {
        defer { startingFilter = nil }
        guard let startingFilter, let index = filters.firstIndex(of: startingFilter) else { return }
        filters.remove(at: index)
    }

    mutating func addFilter(forColumn columnName: String, settings: FilterSettings) {
        dropUntouchedStartingFilter()
        filters.append(TableFilter(
            columnName: columnName,
            filterOperator: settings.defaultOperator.toFilterOperator()
        ))
        isVisible = true
        leaveTextMode()
    }

    static func crossColumnSearchFilters(term: String, columns: [String]) -> [TableFilter] {
        columns.map { column in
            TableFilter(columnName: column, filterOperator: .contains, value: term)
        }
    }

    mutating func setReferenceFilter(_ filter: TableFilter) {
        filters = [filter]
        commit = .all
        isVisible = true
        filterLogicMode = .and
        leaveTextMode()
    }

    mutating func applySingleFilter(_ filter: TableFilter) {
        guard filter.isValid else { return }
        filters = [filter]
        commit = .all
        isVisible = true
        leaveTextMode()
    }

    @discardableResult
    mutating func duplicateFilter(_ filter: TableFilter) -> UUID {
        let copy = filter.duplicated()
        if let index = filters.firstIndex(where: { $0.id == filter.id }) {
            filters.insert(copy, at: index + 1)
        } else {
            filters.append(copy)
        }
        return copy.id
    }

    mutating func updateFilter(_ filter: TableFilter) {
        guard let index = filters.firstIndex(where: { $0.id == filter.id }) else { return }
        filters[index] = filter
    }

    /// Judged against what is running rather than the draft, so a running row whose text was
    /// erased without Apply still stops running when the reader removes it.
    @discardableResult
    mutating func removeFilter(_ filter: TableFilter) -> RemoveFilterOutcome {
        let outcome = Self.removeFilterOutcome(removing: filter, from: rerunFilters.filters)
        filters.removeAll { $0.id == filter.id }
        if case .solo(let id) = commit, id == filter.id {
            commit = nil
        }
        return outcome
    }

    static func removeFilterOutcome(
        removing filter: TableFilter,
        from appliedFilters: [TableFilter]
    ) -> RemoveFilterOutcome {
        guard appliedFilters.contains(where: { $0.id == filter.id }) else { return .noChange }
        let remaining = appliedFilters.filter { $0.id != filter.id }
        return remaining.isEmpty ? .clear : .reapply(remaining)
    }

    /// Whether a row in the draft or in what is running compares on one of these columns, so an edit
    /// to them changes the filters and has to rerun them and be undoable with them.
    func filtersOnAnyColumn(in names: Set<String>) -> Bool {
        (filters + executedFilters).contains { !$0.isRawSQL && names.contains($0.columnName) }
    }

    /// A column the rows filter on was renamed: the draft and what is running both follow it, or a
    /// rerun would look for the old name and drop the condition.
    mutating func renameFilterColumn(from oldName: String, to newName: String) {
        let rename = { (rows: inout [TableFilter]) in
            for index in rows.indices where !rows[index].isRawSQL && rows[index].columnName == oldName {
                rows[index].columnName = newName
            }
        }
        rename(&filters)
        rename(&executedFilters)
    }

    /// Columns were removed, so no row can filter on them any more, in the draft or what is running.
    mutating func removeFilters(onColumns names: Set<String>) {
        let readsRemoved = { (row: TableFilter) in !row.isRawSQL && names.contains(row.columnName) }
        filters.removeAll(where: readsRemoved)
        executedFilters.removeAll(where: readsRemoved)
    }

    mutating func setAllFiltersEnabled(_ isEnabled: Bool) {
        for index in filters.indices {
            filters[index].isEnabled = isEnabled
        }
    }

    /// The tab moves to another table, so a sort draft on this one's columns goes too.
    mutating func clearFilters() {
        filters = []
        commit = nil
        sortDraft = nil
        leaveTextMode()
    }

    mutating func loadPreset(_ preset: FilterPreset) {
        filters = preset.filters
        leaveTextMode()
    }

    static func filterMove(
        in filters: [TableFilter],
        moving draggedID: UUID,
        onto targetID: UUID
    ) -> FilterMove? {
        guard draggedID != targetID,
              let from = filters.firstIndex(where: { $0.id == draggedID }),
              let target = filters.firstIndex(where: { $0.id == targetID }) else { return nil }
        return FilterMove(source: IndexSet(integer: from), destination: from < target ? target + 1 : target)
    }

    static func filterMove(
        in filters: [TableFilter],
        moving filterID: UUID,
        direction: FilterMoveDirection
    ) -> FilterMove? {
        guard let from = filters.firstIndex(where: { $0.id == filterID }) else { return nil }
        switch direction {
        case .up:
            guard from > 0 else { return nil }
            return FilterMove(source: IndexSet(integer: from), destination: from - 1)
        case .down:
            guard from < filters.count - 1 else { return nil }
            return FilterMove(source: IndexSet(integer: from), destination: from + 2)
        }
    }

    mutating func moveFilter(_ draggedID: UUID, onto targetID: UUID) {
        guard let move = Self.filterMove(in: filters, moving: draggedID, onto: targetID) else { return }
        filters.move(fromOffsets: move.source, toOffset: move.destination)
    }

    mutating func moveFilter(_ filterID: UUID, direction: FilterMoveDirection) {
        guard let move = Self.filterMove(in: filters, moving: filterID, direction: direction) else { return }
        filters.move(fromOffsets: move.source, toOffset: move.destination)
    }

    func canMoveFilter(_ filterID: UUID, direction: FilterMoveDirection) -> Bool {
        Self.filterMove(in: filters, moving: filterID, direction: direction) != nil
    }

    /// Whether the rows on screen were already fetched with this condition, so adding it would
    /// change nothing but the page.
    static func isRunning(_ filter: TableFilter, in state: TabFilterState) -> Bool {
        guard state.executedFilters.contains(where: { $0.hasSameCondition(as: filter) }) else { return false }
        return (state.executedLogicMode ?? state.filterLogicMode) == .and || state.executedFilters.count == 1
    }

    /// The filter state that shows what the grid showed, and only rows matching `filter` too.
    ///
    /// What the grid showed is `executedFilters`, never `appliedFilters`: rows typed and never
    /// applied, and rows left in the panel by Clear, resolve as applied under `.all` without having
    /// run. So a row stays checked only when it is running, every other row is unchecked rather than
    /// removed, and the commit becomes `.all` over exactly the checked rows, which is also what the
    /// saved state restores. A row that already holds the condition is checked instead of repeated.
    ///
    /// Under Match any, a condition can only be added to one running row or none, where the two
    /// modes agree and the mode becomes Match all. With two or more running rows the condition
    /// cannot join them, so it runs alone.
    static func cellFilterState(_ state: TabFilterState, adding filter: TableFilter) -> TabFilterState {
        var state = state
        state.dropUntouchedStartingFilter()
        let executedIDs = Set(state.executedFilters.map(\.id))
        let runningIDs = Set(state.filters.lazy.map(\.id).filter(executedIDs.contains))
        let keepsRunningRows = (state.executedLogicMode ?? state.filterLogicMode) == .and || runningIDs.count <= 1
        let keptIDs = keepsRunningRows ? runningIDs : []
        let existingID = state.filters.first { $0.hasSameCondition(as: filter) }?.id

        var next = state
        next.filters = state.filters.map { row in
            var row = row
            row.isEnabled = keptIDs.contains(row.id) || row.id == existingID
            return row
        }
        if existingID == nil {
            var added = filter
            added.isEnabled = true
            next.filters.append(added)
        }
        if keepsRunningRows {
            next.filterLogicMode = .and
        }
        next.commit = .all
        next.isVisible = true
        next.leaveTextMode()
        return next
    }
}
