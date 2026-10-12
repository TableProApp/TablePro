//
//  ColumnValueFilterSelectionTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

struct ColumnValueFilterSelectionTests {
    private static let ids = ["1", "12", "122", "1122", "1220", "5"].map { value($0) }
    private static let nullValue = ColumnDistinctValue(display: "", isNull: true, count: 2)
    private static let emptyValue = value("")

    private static func value(_ display: String) -> ColumnDistinctValue {
        ColumnDistinctValue(display: display, isNull: false, count: 1)
    }

    private static func displays(_ values: [ColumnDistinctValue]) -> [String] {
        values.map(\.display)
    }

    @Test("Everything selected and no search clears the column's filter")
    func everythingSelectedClearsTheFilter() {
        let selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)

        #expect(selection.appliedFilter == nil)
        #expect(selection.canApply)
        #expect(selection.allVisibleSelectedState == true)
    }

    @Test("A search selects every value containing it, and applying keeps only those")
    func searchKeepsOnlyTheMatches() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)

        selection.setSearchText("122")

        #expect(selection.isSearching)
        #expect(Self.displays(selection.visibleValues) == ["122", "1122", "1220"])
        #expect(selection.allVisibleSelectedState == true)
        #expect(
            selection.appliedFilter
                == ColumnValueFilter(selectedValues: ["122", "1122", "1220"], includesNull: false)
        )
    }

    @Test("A search that matches every value clears the column's filter")
    func searchMatchingEverythingClearsTheFilter() {
        var selection = ColumnValueFilterSelection(values: [Self.value("a1"), Self.value("a2")], initialFilter: nil)

        selection.setSearchText("a")

        #expect(selection.appliedFilter == nil)
    }

    @Test("A search with no matches cannot be applied")
    func searchWithNoMatchesCannotApply() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)

        selection.setSearchText("zzz")

        #expect(selection.visibleValues.isEmpty)
        #expect(selection.canApply == false)
        #expect(selection.allVisibleSelectedState == false)
    }

    @Test("Select All while searching changes the matches and leaves hidden values alone")
    func selectAllActsOnTheMatchesOnly() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)
        selection.setSearchText("12")

        selection.toggleAllVisible()

        #expect(selection.allVisibleSelectedState == false)
        #expect(selection.canApply == false)

        selection.setSelected(true, for: Self.value("122"))

        #expect(selection.allVisibleSelectedState == nil)
        #expect(selection.appliedFilter == ColumnValueFilter(selectedValues: ["122"], includesNull: false))

        selection.setSearchText("")

        #expect(selection.isSelected(Self.value("5")))
        #expect(selection.appliedFilter == nil)
    }

    @Test("Select All selects every match when some are selected")
    func selectAllFromMixedSelectsEveryMatch() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)
        selection.setSearchText("12")
        selection.setSelected(false, for: Self.value("1220"))

        selection.toggleAllVisible()

        #expect(selection.allVisibleSelectedState == true)
    }

    @Test("Clearing the search brings back the selection made before it")
    func clearingTheSearchRestoresThePreviousSelection() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)
        selection.setSelected(false, for: Self.value("5"))
        selection.setSearchText("12")
        selection.setSelected(false, for: Self.value("1220"))

        selection.setSearchText("")

        #expect(selection.isSearching == false)
        #expect(Self.displays(selection.visibleValues) == Self.displays(Self.ids))
        #expect(selection.isSelected(Self.value("5")) == false)
        #expect(selection.isSelected(Self.value("1220")))
        #expect(
            selection.appliedFilter
                == ColumnValueFilter(selectedValues: ["1", "12", "122", "1122", "1220"], includesNull: false)
        )
    }

    @Test("Each change to the search selects its matches again")
    func refiningTheSearchReselectsItsMatches() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)
        selection.setSearchText("12")
        selection.setSelected(false, for: Self.value("122"))

        selection.setSearchText("122")

        #expect(selection.isSelected(Self.value("122")))
        #expect(selection.allVisibleSelectedState == true)
    }

    @Test("Spaces around the search are not part of it")
    func spacesAroundTheSearchAreIgnored() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)

        selection.setSearchText(" 122 ")

        #expect(selection.searchText == " 122 ")
        #expect(Self.displays(selection.visibleValues) == ["122", "1122", "1220"])
    }

    @Test("Spaces alone are not a search")
    func spacesAloneAreNotASearch() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)

        selection.setSearchText("   ")

        #expect(selection.isSearching == false)
        #expect(selection.visibleValues.count == Self.ids.count)
    }

    @Test("Typing a space after the search keeps the selection made in it")
    func trailingSpaceKeepsTheSearchSelection() {
        var selection = ColumnValueFilterSelection(values: Self.ids, initialFilter: nil)
        selection.setSearchText("12")
        selection.setSelected(false, for: Self.value("122"))

        selection.setSearchText("12 ")

        #expect(selection.isSelected(Self.value("122")) == false)
    }

    @Test("A search replaces the filter the column already has")
    func searchReplacesTheExistingFilter() {
        let values = [Self.value("paid"), Self.value("pending"), Self.value("refunded")]
        var selection = ColumnValueFilterSelection(
            values: values,
            initialFilter: ColumnValueFilter(selectedValues: ["paid"], includesNull: false)
        )

        selection.setSearchText("ref")

        #expect(selection.isSelected(Self.value("refunded")))
        #expect(selection.appliedFilter == ColumnValueFilter(selectedValues: ["refunded"], includesNull: false))
    }

    @Test("Searching ignores case")
    func searchIgnoresCase() {
        var selection = ColumnValueFilterSelection(values: [Self.value("Paid"), Self.value("unpaid"), Self.value("open")], initialFilter: nil)

        selection.setSearchText("PAID")

        #expect(Self.displays(selection.visibleValues) == ["Paid", "unpaid"])
    }

    @Test("The NULL entry is found by its label and kept as NULL")
    func nullIsFoundByItsLabel() {
        var selection = ColumnValueFilterSelection(values: [Self.value("a"), Self.nullValue], initialFilter: nil)

        selection.setSearchText(Self.nullValue.label)

        #expect(selection.visibleValues == [Self.nullValue])
        #expect(selection.appliedFilter == ColumnValueFilter(selectedValues: [], includesNull: true))
    }

    @Test("The empty string is found by its label and kept as an empty string")
    func emptyStringIsFoundByItsLabel() {
        var selection = ColumnValueFilterSelection(values: [Self.value("a"), Self.emptyValue], initialFilter: nil)

        selection.setSearchText(Self.emptyValue.label)

        #expect(selection.visibleValues == [Self.emptyValue])
        #expect(selection.appliedFilter == ColumnValueFilter(selectedValues: [""], includesNull: false))
    }

    @Test("Values the filter keeps but the list no longer shows survive an apply without a search")
    func unlistedFilterValuesSurviveWithoutASearch() {
        let filter = ColumnValueFilter(selectedValues: ["a", "gone"], includesNull: false)
        let selection = ColumnValueFilterSelection(values: [Self.value("a"), Self.value("b")], initialFilter: filter)

        #expect(selection.allVisibleSelectedState == nil)
        #expect(selection.appliedFilter == filter)
    }

    @Test("Select All drops filter values the list no longer shows")
    func selectAllDropsUnlistedFilterValues() {
        let filter = ColumnValueFilter(selectedValues: ["a", "gone"], includesNull: false)
        var selection = ColumnValueFilterSelection(values: [Self.value("a"), Self.value("b")], initialFilter: filter)

        selection.toggleAllVisible()

        #expect(selection.appliedFilter == nil)

        selection.toggleAllVisible()

        #expect(selection.canApply == false)
    }

    @Test("A filter value the list no longer shows cannot be applied alone")
    func unlistedFilterValueAloneCannotApply() {
        let filter = ColumnValueFilter(selectedValues: ["a", "gone"], includesNull: false)
        var selection = ColumnValueFilterSelection(values: [Self.value("a"), Self.value("b")], initialFilter: filter)

        selection.setSelected(false, for: Self.value("a"))

        #expect(selection.allVisibleSelectedState == false)
        #expect(selection.canApply == false)
    }

    @Test("Deselecting everything cannot be applied")
    func emptySelectionCannotApply() {
        var selection = ColumnValueFilterSelection(values: Self.ids + [Self.nullValue], initialFilter: nil)

        selection.toggleAllVisible()

        #expect(selection.allVisibleSelectedState == false)
        #expect(selection.canApply == false)
    }

    @Test("A column with no values cannot be applied")
    func noValuesCannotApply() {
        var selection = ColumnValueFilterSelection(values: [], initialFilter: nil)

        selection.toggleAllVisible()

        #expect(selection.canApply == false)
        #expect(selection.allVisibleSelectedState == false)
    }
}
