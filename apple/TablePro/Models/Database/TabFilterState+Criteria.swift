//
//  TabFilterState+Criteria.swift
//  TablePro
//

import Foundation

/// How the filter panel edits its conditions: a row per condition, or one typed WHERE condition.
enum FilterEditMode: String, Codable, Hashable {
    case builder
    case text
}

/// One key of the Sort By section. Keyed by column name, because a column sorts once.
struct FilterSortCriterion: Identifiable, Equatable, Hashable {
    var columnName: String
    var direction: SortDirection

    var id: String { columnName }
}

/// What the builder held when Text mode replaced it, so a round trip that typed nothing loses nothing.
struct FilterTextModeOrigin: Equatable, Hashable {
    let filters: [TableFilter]
    let logicMode: FilterLogicMode
    let text: String
}

internal extension TabFilterState {
    // MARK: - Builder and Text

    /// Text mode holds exactly one raw row. Anything else put rows in from outside the editor (a
    /// cell's Filter menu, a preset, a reference jump), and those rows only make sense as rows.
    var effectiveEditMode: FilterEditMode {
        guard editMode == .text, filters.count == 1, filters[0].isRawSQL else { return .builder }
        return .text
    }

    /// The typed condition Text mode edits.
    var textCondition: String {
        effectiveEditMode == .text ? filters[0].value : ""
    }

    mutating func setTextCondition(_ text: String) {
        guard effectiveEditMode == .text else { return }
        filters[0].value = text
    }

    /// Replaces the rows with one raw row holding `condition`, the WHERE text the enabled rows
    /// produce. No SQL is parsed either way, so the rows are kept aside for a return that typed
    /// nothing. A solo commit names a row that is gone, so what was applied reads as every row.
    /// Returns the raw row's id, for the editor to take focus.
    @discardableResult
    mutating func enterTextMode(condition: String) -> UUID? {
        guard effectiveEditMode == .builder else { return filters.first?.id }
        let row = TableFilter.rawCondition(condition)
        textModeOrigin = FilterTextModeOrigin(
            filters: filters,
            logicMode: filterLogicMode,
            text: condition
        )
        filters = [row]
        filterLogicMode = .and
        if commit != nil {
            commit = .all
        }
        editMode = .text
        return row.id
    }

    /// Keeps what was typed as one raw-SQL row. Text that is still what the rows produced brings
    /// the rows back instead, with their enabled flags and logic mode. The commit stays as it is
    /// now: an Apply or Clear in Text mode changed what is running, and a rerun reads that from
    /// `executedFilters`, never from the rows.
    mutating func enterBuilderMode() {
        defer { leaveTextMode() }
        guard effectiveEditMode == .text,
              let origin = textModeOrigin,
              origin.text == textCondition else { return }
        filters = origin.filters
        filterLogicMode = origin.logicMode
    }

    /// Rows put in from outside the editor are builder rows.
    mutating func leaveTextMode() {
        editMode = .builder
        textModeOrigin = nil
    }

    // MARK: - Sort draft

    /// What the Sort By section shows: the draft, or the sort the rows were fetched with.
    func sortCriteria(applied: [FilterSortCriterion]) -> [FilterSortCriterion] {
        sortDraft ?? applied
    }

    /// Every edit starts from what the section shows, so the first one seeds the draft from the tab.
    mutating func editSortDraft(applied: [FilterSortCriterion], _ edit: (inout [FilterSortCriterion]) -> Void) {
        var draft = sortCriteria(applied: applied)
        edit(&draft)
        sortDraft = draft
    }

    /// Adds the first column no key sorts by yet, so a column never sorts twice.
    mutating func addSortCriterion(
        applied: [FilterSortCriterion],
        columns: [String],
        direction: SortDirection
    ) {
        let used = Set(sortCriteria(applied: applied).map(\.columnName))
        guard let column = columns.first(where: { !used.contains($0) }) else { return }
        editSortDraft(applied: applied) { $0.append(FilterSortCriterion(columnName: column, direction: direction)) }
    }

    mutating func removeSortCriterion(_ columnName: String, applied: [FilterSortCriterion]) {
        editSortDraft(applied: applied) { $0.removeAll { $0.columnName == columnName } }
    }

    /// A column another key already sorts by is refused, so the keys stay unique.
    mutating func updateSortCriterion(
        _ columnName: String,
        to replacement: FilterSortCriterion,
        applied: [FilterSortCriterion]
    ) {
        editSortDraft(applied: applied) { draft in
            guard let index = draft.firstIndex(where: { $0.columnName == columnName }) else { return }
            let takenElsewhere = draft.indices.contains { $0 != index && draft[$0].columnName == replacement.columnName }
            guard !takenElsewhere else { return }
            draft[index] = replacement
        }
    }

    // MARK: - Edited state

    /// Whether Apply Filter & Sort would fetch rows other than the ones on screen: the rows Apply
    /// runs (every enabled, complete row) against the filters the rows were fetched with, and the
    /// sort draft against the tab's sort. An incomplete or unchecked row runs nothing, so it edits
    /// nothing.
    func criteriaDiffer(fromAppliedSort appliedSort: [FilterSortCriterion]) -> Bool {
        filterDraftDiffersFromRunning || (sortDraft.map { $0 != appliedSort } ?? false)
    }

    var filterDraftDiffersFromRunning: Bool {
        let draft = Self.resolve(.all, in: filters)
        let running = rerunFilters
        guard draft.count == running.filters.count,
              zip(draft, running.filters).allSatisfy({ $0.hasSameCondition(as: $1) }) else { return true }
        return draft.count > 1 && filterLogicMode != running.logicMode
    }

    // MARK: - Sort conversion

    /// The tab's sort as section keys, named from the grid's columns. A key whose column cannot be
    /// named, or that repeats a column, has nothing the section could show.
    static func sortCriteria(from sortState: SortState, columns: [String]) -> [FilterSortCriterion] {
        var seen = Set<String>()
        return sortState.columns.compactMap { column in
            guard let name = SortColumnResolver.columnName(for: column, displayColumns: columns),
                  seen.insert(name).inserted else { return nil }
            return FilterSortCriterion(columnName: name, direction: column.direction)
        }
    }

    /// The section's keys as the sort a table query carries, each stamped with its name and its
    /// position in `columns`. A key on a column the result no longer has is dropped rather than
    /// pointed at another column.
    static func sortState(from criteria: [FilterSortCriterion], columns: [String]) -> SortState {
        let sortColumns = criteria.compactMap { criterion -> SortColumn? in
            guard let index = columns.firstIndex(of: criterion.columnName) else { return nil }
            return SortColumn(columnIndex: index, direction: criterion.direction, columnName: criterion.columnName)
        }
        return SortState(columns: sortColumns, source: .user)
    }
}
