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

    // A row's add button puts the new row right under it, as NSRuleEditor does; without one it goes last.
    @discardableResult
    mutating func addFilter(
        settings: FilterSettings,
        columns: [String],
        primaryKeyColumn: String?,
        offersRawFilter: Bool,
        after anchorID: UUID? = nil
    ) -> UUID {
        let filter = Self.newFilter(
            settings: settings,
            columns: columns,
            primaryKeyColumn: primaryKeyColumn,
            offersRawFilter: offersRawFilter
        )
        if let anchorID, let index = filters.firstIndex(where: { $0.id == anchorID }) {
            filters.insert(filter, at: index + 1)
        } else {
            filters.append(filter)
        }
        return filter.id
    }

    mutating func addFilter(forColumn columnName: String, settings: FilterSettings) {
        filters.append(TableFilter(
            columnName: columnName,
            filterOperator: settings.defaultOperator.toFilterOperator()
        ))
        isVisible = true
    }

    static func crossColumnSearchFilters(term: String, columns: [String]) -> [TableFilter] {
        columns.map { column in
            TableFilter(columnName: column, filterOperator: .contains, value: term)
        }
    }

    // The search becomes the panel's rows, so a page turn reruns it and the reader can see and edit it.
    func searchingAllRows(term: String, columns: [String]) -> TabFilterState {
        var next = self
        next.filters = Self.crossColumnSearchFilters(term: term, columns: columns)
        next.filterLogicMode = .or
        next.applied = .checkedRows(of: next.filters, logicMode: .or)
        next.isVisible = true
        return next
    }

    mutating func setReferenceFilter(_ filter: TableFilter) {
        filters = [filter]
        filterLogicMode = .and
        applied = .checkedRows(of: filters, logicMode: .and)
        isVisible = true
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

    func applyingCheckedRows() -> TabFilterState {
        var next = self
        next.applied = .checkedRows(of: filters, logicMode: filterLogicMode)
        return next
    }

    func applyingAlone(_ filterID: UUID) -> TabFilterState? {
        guard let row = filters.first(where: { $0.id == filterID }),
              let alone = AppliedFilters.alone(row, logicMode: filterLogicMode) else { return nil }
        var next = self
        next.applied = alone
        return next
    }

    func applyingCurrentMode() -> TabFilterState {
        var next = self
        next.applied = applicationInCurrentMode
        return next
    }

    func turningOff() -> TabFilterState {
        var next = self
        next.applied = nil
        return next
    }

    // Removing a row stops only that row: the rest keep running as they ran, unapplied edits stay drafts.
    // The bar closes with its last row, as it does after Remove All.
    func removingFilter(_ filterID: UUID) -> TabFilterState {
        var next = self
        next.filters.removeAll { $0.id == filterID }
        next.applied = applied?.removing(filterID)
        if next.filters.isEmpty {
            next.isVisible = false
        }
        return next
    }

    func removingAllFilters() -> TabFilterState {
        var next = self
        next.filters = []
        next.applied = nil
        next.isVisible = false
        return next
    }

    mutating func clearFilters() {
        filters = []
        applied = nil
    }

    func filtersOnAnyColumn(in names: Set<String>) -> Bool {
        (filters + (applied?.filters ?? [])).contains { !$0.isRawSQL && names.contains($0.columnName) }
    }

    // The draft and what runs both follow a renamed column, or a rerun would look for the old name.
    mutating func renameFilterColumn(from oldName: String, to newName: String) {
        remapColumns { $0 == oldName ? newName : $0 }
    }

    mutating func removeFilters(onColumns names: Set<String>) {
        remapColumns { names.contains($0) ? nil : $0 }
    }

    // One pass, so two columns that trade names move together instead of landing on the same one.
    // A nil name removes the row.
    mutating func remapColumns(_ newName: (String) -> String?) {
        filters = Self.remapping(filters, newName)
        applied = applied?.mapFilters { Self.remapping($0, newName) }
    }

    private static func remapping(_ rows: [TableFilter], _ newName: (String) -> String?) -> [TableFilter] {
        rows.compactMap { row in
            guard !row.isRawSQL else { return row }
            guard let name = newName(row.columnName) else { return nil }
            var moved = row
            moved.columnName = name
            return moved
        }
    }

    mutating func setAllFiltersEnabled(_ isEnabled: Bool) {
        for index in filters.indices {
            filters[index].isEnabled = isEnabled
        }
    }

    mutating func loadPreset(_ preset: FilterPreset) {
        filters = preset.filters
        if let logicMode = preset.logicMode {
            filterLogicMode = logicMode
        }
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

    // Adding a condition the rows were already fetched with would change nothing but the page.
    static func isRunning(_ filter: TableFilter, in state: TabFilterState) -> Bool {
        guard let applied = state.applied,
              applied.filters.contains(where: { $0.hasSameCondition(as: filter) }) else { return false }
        return applied.logicMode == .and || applied.filters.count == 1
    }

    // What the grid showed, narrowed by `filter` too. A row stays checked only when it is running, so
    // the checked rows are exactly what runs, which is also what the saved state restores. Under
    // Match any, a condition can join one running row or none; with two or more it runs alone.
    static func cellFilterState(_ state: TabFilterState, adding filter: TableFilter) -> TabFilterState {
        let applied = state.applied
        let runningIDs = Set(applied?.filters.map(\.id) ?? []).intersection(state.filters.map(\.id))
        let keepsRunningRows = applied.map { $0.logicMode == .and || $0.filters.count <= 1 } ?? true
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
        next.applied = .checkedRows(of: next.filters, logicMode: next.filterLogicMode)
        next.isVisible = true
        return next
    }
}
