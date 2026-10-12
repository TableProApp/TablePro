//
//  ColumnValueFilterSelection.swift
//  TablePro
//

import Foundation

/// A search narrows the selection, not only the list. The selection made before it comes back when
/// the search is cleared, because only Cancel may discard work in a popover.
struct ColumnValueFilterSelection {
    let values: [ColumnDistinctValue]
    private(set) var searchText = ""
    private var query = ""
    /// Stored rather than derived: the list, Select All and Apply all read it on every render, and
    /// a column can hold tens of thousands of distinct values.
    private(set) var visibleValues: [ColumnDistinctValue]
    private var listSelection: ColumnValueFilter
    private var searchSelection: ColumnValueFilter?

    init(values: [ColumnDistinctValue], initialFilter: ColumnValueFilter?) {
        self.values = values
        visibleValues = values
        listSelection = initialFilter ?? ColumnValueFilter(keeping: values)
    }

    var isSearching: Bool { searchSelection != nil }

    /// `true` when every visible value is selected, `false` when none is, `nil` when mixed.
    var allVisibleSelectedState: Bool? {
        let selection = activeSelection
        let selectedCount = visibleValues.reduce(0) { $0 + (selection.keeps($1) ? 1 : 0) }
        if selectedCount == 0 { return false }
        return selectedCount == visibleValues.count ? true : nil
    }

    /// The one rule for both Apply and Return in the search field. A filter value the list no
    /// longer shows does not count: no loaded row holds it, so applying it alone hides every row.
    var canApply: Bool {
        let selection = activeSelection
        return visibleValues.contains { selection.keeps($0) }
    }

    /// `nil` when the selection keeps every listed value, which clears the column's filter. Decided
    /// over every value, not the visible ones, so a search that selects all its matches still
    /// filters to them.
    var appliedFilter: ColumnValueFilter? {
        let selection = activeSelection
        return values.allSatisfy { selection.keeps($0) } ? nil : selection
    }

    func isSelected(_ value: ColumnDistinctValue) -> Bool {
        activeSelection.keeps(value)
    }

    mutating func setSelected(_ isSelected: Bool, for value: ColumnDistinctValue) {
        editActiveSelection { $0.set(value, kept: isSelected) }
    }

    /// Replaces the selection rather than editing it, so it also drops filter values the list no
    /// longer shows.
    mutating func toggleAllVisible() {
        let replacement = allVisibleSelectedState == true
            ? ColumnValueFilter(selectedValues: [], includesNull: false)
            : ColumnValueFilter(keeping: visibleValues)
        editActiveSelection { $0 = replacement }
    }

    /// Every change to what is searched for selects all of its matches again. The text keeps its
    /// spaces for the field, which writes the binding back while the user is still typing.
    mutating func setSearchText(_ text: String) {
        searchText = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        guard !trimmed.isEmpty else {
            visibleValues = values
            searchSelection = nil
            return
        }
        visibleValues = values.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
        searchSelection = ColumnValueFilter(keeping: visibleValues)
    }

    private var activeSelection: ColumnValueFilter {
        searchSelection ?? listSelection
    }

    private mutating func editActiveSelection(_ edit: (inout ColumnValueFilter) -> Void) {
        if var selection = searchSelection {
            edit(&selection)
            searchSelection = selection
        } else {
            edit(&listSelection)
        }
    }
}

internal extension ColumnDistinctValue {
    /// What the popover lists and what its search matches, so "null" finds the NULL entry.
    var label: String {
        if isNull { return String(localized: "(NULL)") }
        return display.isEmpty ? String(localized: "(Empty)") : display
    }
}

private extension ColumnValueFilter {
    init(keeping values: [ColumnDistinctValue]) {
        self.init(
            selectedValues: Set(values.lazy.filter { !$0.isNull }.map(\.display)),
            includesNull: values.contains { $0.isNull }
        )
    }

    func keeps(_ value: ColumnDistinctValue) -> Bool {
        value.isNull ? includesNull : selectedValues.contains(value.display)
    }

    mutating func set(_ value: ColumnDistinctValue, kept: Bool) {
        if value.isNull {
            includesNull = kept
        } else if kept {
            selectedValues.insert(value.display)
        } else {
            selectedValues.remove(value.display)
        }
    }
}
