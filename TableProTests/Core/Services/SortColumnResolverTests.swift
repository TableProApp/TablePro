import Foundation
@testable import TablePro
import Testing

@Suite("SortColumnResolver")
struct SortColumnResolverTests {
    private let displayColumns = ["_id", "name", "email", "createdAt"]

    @Test("A stamped name wins over the stored index")
    func stampedNameWins() {
        let sortColumn = SortColumn(columnIndex: 0, direction: .ascending, columnName: "createdAt")
        #expect(SortColumnResolver.columnName(for: sortColumn, displayColumns: displayColumns) == "createdAt")
    }

    @Test("An unstamped column falls back to its position in the display list")
    func fallsBackToIndex() {
        let sortColumn = SortColumn(columnIndex: 3, direction: .ascending)
        #expect(SortColumnResolver.columnName(for: sortColumn, displayColumns: displayColumns) == "createdAt")
    }

    @Test("An out-of-range index with no name resolves to nothing")
    func outOfRangeUnstamped() {
        let sortColumn = SortColumn(columnIndex: 42, direction: .ascending)
        #expect(SortColumnResolver.columnName(for: sortColumn, displayColumns: displayColumns) == nil)
    }

    @Test("An out-of-range index still resolves when the name was stamped")
    func outOfRangeStamped() {
        let sortColumn = SortColumn(columnIndex: 42, direction: .ascending, columnName: "createdAt")
        #expect(SortColumnResolver.columnName(for: sortColumn, displayColumns: displayColumns) == "createdAt")
    }

    @Test("Stamping records the name each position refers to")
    func stampingRecordsNames() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending),
            SortColumn(columnIndex: 1, direction: .ascending),
        ])
        let stamped = SortColumnResolver.stamped(state, displayColumns: displayColumns)
        #expect(stamped.columns.map(\.columnName) == ["createdAt", "name"])
        #expect(stamped.columns.map(\.columnIndex) == [3, 1])
        #expect(stamped.columns.map(\.direction) == [.descending, .ascending])
    }

    // MARK: - Resolution against a different target list

    /// The reported bug: the grid indexes the full result while a scoped browse query hands
    /// the driver a shorter list. Index 3 in the display list is index 1 in the scoped one.
    @Test("An index is re-resolved into the list the consumer actually reads")
    func reResolvesIntoTargetList() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending, columnName: "createdAt"),
        ])
        let resolved = SortColumnResolver.resolvedIndices(
            for: state,
            displayColumns: displayColumns,
            targetColumns: ["_id", "createdAt"]
        )
        #expect(resolved.count == 1)
        #expect(resolved[0].columnIndex == 1)
        #expect(resolved[0].ascending == false)
    }

    @Test("A sort column missing from the target list is dropped, never approximated")
    func missingFromTargetIsDropped() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .ascending, columnName: "createdAt"),
        ])
        let resolved = SortColumnResolver.resolvedIndices(
            for: state,
            displayColumns: displayColumns,
            targetColumns: ["_id", "name"]
        )
        #expect(resolved.isEmpty)
    }

    @Test("Multi-column sort keeps its order and directions across lists")
    func multiColumnSurvives() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending, columnName: "createdAt"),
            SortColumn(columnIndex: 1, direction: .ascending, columnName: "name"),
        ])
        let resolved = SortColumnResolver.resolvedIndices(
            for: state,
            displayColumns: displayColumns,
            targetColumns: ["email", "name", "createdAt"]
        )
        #expect(resolved.map(\.columnIndex) == [2, 1])
        #expect(resolved.map(\.ascending) == [false, true])
    }

    @Test("No sort state resolves to no sort columns")
    func noSortState() {
        #expect(SortColumnResolver.resolvedIndices(
            for: nil,
            displayColumns: displayColumns,
            targetColumns: displayColumns
        ).isEmpty)
    }

    // MARK: - Reindexing for the header

    /// The header draws its chevron and runs its click cycle off columnIndex, so a stale index
    /// puts the affordance on the wrong column while the rows are ordered correctly.
    @Test("Reindexing re-points a sort at its column's new position")
    func reindexingRepointsSort() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .descending, columnName: "createdAt"),
        ])
        let reindexed = SortColumnResolver.reindexed(state, displayColumns: ["_id", "email", "createdAt"])
        #expect(reindexed.columns.map(\.columnIndex) == [2])
        #expect(reindexed.columns.map(\.columnName) == ["createdAt"])
        #expect(reindexed.columns.map(\.direction) == [.descending])
    }

    @Test("Reindexing stamps a name onto an entry that had none")
    func reindexingStampsMissingName() {
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .ascending)])
        let reindexed = SortColumnResolver.reindexed(state, displayColumns: displayColumns)
        #expect(reindexed.columns.map(\.columnName) == ["name"])
        #expect(reindexed.columns.map(\.columnIndex) == [1])
    }

    @Test("Reindexing keeps an entry whose column is not currently listed")
    func reindexingKeepsUnlistedEntry() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .ascending, columnName: "createdAt"),
        ])
        let reindexed = SortColumnResolver.reindexed(state, displayColumns: ["_id", "name"])
        #expect(reindexed.columns.count == 1)
        #expect(reindexed.columns[0].columnName == "createdAt")
    }

    // MARK: - Clause naming

    @Test("A clause prefers a stamped name the list still carries")
    func clausePrefersStampedName() {
        let sortColumn = SortColumn(columnIndex: 0, direction: .ascending, columnName: "createdAt")
        #expect(SortColumnResolver.clauseColumnName(for: sortColumn, displayColumns: displayColumns) == "createdAt")
    }

    /// A renamed column keeps its position, so the position is the fresher of the two and the
    /// clause must not spell out an identifier the server no longer knows.
    @Test("A clause falls back to the position when the stamped name is gone")
    func clauseFallsBackAfterRename() {
        let sortColumn = SortColumn(columnIndex: 1, direction: .ascending, columnName: "old_name")
        let renamed = ["_id", "new_name", "email"]
        #expect(SortColumnResolver.clauseColumnName(for: sortColumn, displayColumns: renamed) == "new_name")
    }

    @Test("A clause still names a scoped-out column when the position cannot help")
    func clauseKeepsScopedOutName() {
        let sortColumn = SortColumn(columnIndex: 9, direction: .ascending, columnName: "createdAt")
        #expect(SortColumnResolver.clauseColumnName(for: sortColumn, displayColumns: ["_id"]) == "createdAt")
    }

    @Test("Column names are collected for retention in the fetch scope")
    func collectsNames() {
        let state = SortState(columns: [
            SortColumn(columnIndex: 3, direction: .ascending, columnName: "createdAt"),
            SortColumn(columnIndex: 99, direction: .ascending),
        ])
        #expect(SortColumnResolver.columnNames(for: state, displayColumns: displayColumns) == ["createdAt"])
    }
}
