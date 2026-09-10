import Foundation
@testable import TablePro
import Testing

@Suite("ColumnFetchScope")
struct ColumnFetchScopeTests {
    private let columns = ["id", "name", "email", "payload"]

    @Test("No hidden columns means no scoping (SELECT *)")
    func noHiddenColumns() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: [], primaryKeyColumns: ["id"]) == nil)
    }

    @Test("Hidden column is dropped, order preserved")
    func dropsHiddenColumn() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["payload"],
            primaryKeyColumns: ["id"]
        )
        #expect(result == ["id", "name", "email"])
    }

    @Test("Primary key is retained even when hidden")
    func retainsHiddenPrimaryKey() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["id", "payload"],
            primaryKeyColumns: ["id"]
        )
        #expect(result == ["id", "name", "email"])
    }

    @Test("Empty schema means no scoping")
    func emptySchema() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: [], hiddenColumns: ["payload"], primaryKeyColumns: []) == nil)
    }

    @Test("Hiding everything with no primary key produces no scoping rather than empty SELECT")
    func hidingEverythingNoPrimaryKey() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: Set(columns), primaryKeyColumns: []) == nil)
    }

    @Test("Hiding columns not present in the schema is a no-op")
    func hiddenColumnsNotInSchema() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: ["ghost"], primaryKeyColumns: ["id"]) == nil)
    }

    // MARK: - prunedHiddenColumns

    @Test("Prune keeps a hidden column that is still in the schema but absent from the scoped result")
    func pruneKeepsSchemaColumnAbsentFromResult() {
        let pruned = ColumnFetchScope.prunedHiddenColumns(
            ["payload"],
            schemaColumns: columns,
            resultColumns: ["id", "name", "email"]
        )
        #expect(pruned == ["payload"])
    }

    @Test("Prune drops a hidden column that no longer exists in the schema")
    func pruneDropsColumnGoneFromSchema() {
        let pruned = ColumnFetchScope.prunedHiddenColumns(
            ["payload", "ghost"],
            schemaColumns: columns,
            resultColumns: ["id", "name", "email"]
        )
        #expect(pruned == ["payload"])
    }

    @Test("Prune without a known schema keeps both hidden and result columns")
    func pruneWithoutSchemaKeepsHiddenAndResult() {
        let pruned = ColumnFetchScope.prunedHiddenColumns(
            ["payload"],
            schemaColumns: nil,
            resultColumns: ["id", "name"]
        )
        #expect(pruned == ["payload"])
    }

    @Test("Prune keeps a hidden column the result carries but the schema sample missed")
    func pruneKeepsResultColumnAbsentFromSchema() {
        let pruned = ColumnFetchScope.prunedHiddenColumns(
            ["latecomer"],
            schemaColumns: columns,
            resultColumns: ["id", "name", "latecomer"]
        )
        #expect(pruned == ["latecomer"])
    }

    // MARK: - Sort column retention

    @Test("A hidden sort column is retained so the browse query can still order by it")
    func retainsHiddenSortColumn() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["email", "payload"],
            primaryKeyColumns: ["id"],
            sortColumns: ["payload"]
        )
        #expect(result == ["id", "name", "payload"])
    }

    @Test("Retention does not duplicate a sort column that is also the primary key")
    func retainsSortColumnThatIsPrimaryKey() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["id", "payload"],
            primaryKeyColumns: ["id"],
            sortColumns: ["id"]
        )
        #expect(result == ["id", "name", "email"])
    }

    /// A schemaless store returns fields the schema sample missed, and the grid lets you sort by
    /// one. A schema-derived projection cannot carry it, so scoping stands down rather than
    /// shipping a query whose sort silently disappears.
    @Test("A sort column the schema does not know disables scoping instead of dropping the sort")
    func sortColumnOutsideSchemaDisablesScoping() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["email"],
            primaryKeyColumns: ["id"],
            sortColumns: ["sparseA"]
        )
        #expect(result == nil)
    }

    @Test("Hiding everything still yields a scope when a sort column survives")
    func hidingEverythingKeepsSortColumn() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: Set(columns),
            primaryKeyColumns: [],
            sortColumns: ["name"]
        )
        #expect(result == ["name"])
    }

    // MARK: - visibilityPickerColumns

    /// The reported bug: a schemaless store returns fields the schema sample never saw, so the
    /// picker never listed them and Hide All, which matches on name, could not hide them.
    @Test("Picker offers result columns the schema sample missed, after the known ones")
    func pickerIncludesResultOnlyColumns() {
        let picker = ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: ["_id", "name"],
            resultColumns: ["_id", "name", "sparseA", "sparseB"],
            hiddenColumns: []
        )
        #expect(picker == ["_id", "name", "sparseA", "sparseB"])
    }

    @Test("Picker keeps schema columns the scoped result dropped")
    func pickerKeepsScopedOutSchemaColumns() {
        let picker = ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: columns,
            resultColumns: ["id", "name"],
            hiddenColumns: ["email", "payload"]
        )
        #expect(picker == columns)
    }

    @Test("Picker never lists a column twice")
    func pickerDeduplicates() {
        let picker = ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: ["id", "name"],
            resultColumns: ["name", "id"],
            hiddenColumns: ["id"]
        )
        #expect(picker == ["id", "name"])
    }

    @Test("Picker falls back to result columns when no schema is cached")
    func pickerWithoutSchema() {
        let picker = ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: nil,
            resultColumns: ["id", "name"],
            hiddenColumns: ["payload"]
        )
        #expect(picker == ["id", "name", "payload"])
    }

    @Test("Hide All over the picker list names every column the grid can render")
    func hideAllCoversEveryRenderedColumn() {
        let resultColumns = ["_id", "name", "sparseA"]
        let picker = ColumnFetchScope.visibilityPickerColumns(
            schemaColumns: ["_id", "name"],
            resultColumns: resultColumns,
            hiddenColumns: []
        )
        #expect(Set(resultColumns).isSubset(of: Set(picker)))
    }
}
