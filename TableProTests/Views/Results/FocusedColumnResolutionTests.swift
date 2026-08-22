//
//  FocusedColumnResolutionTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

/// `focusedColumn` is a position in `tableView.tableColumns`, which carries the row-number column
/// and a hidden spacer ahead of the data and which the reader can reorder. Preview FK Reference
/// used to turn it into a data index by subtracting 1, so the menu command previewed the wrong
/// column or silently nothing while the key-equivalent path on the same cell worked.
@Suite("Focused column resolution")
@MainActor
struct FocusedColumnResolutionTests {
    private func makeGrid(columns: [String]) -> (tableView: NSTableView, schema: ColumnIdentitySchema) {
        let tableView = NSTableView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)

        let schema = ColumnIdentitySchema(columns: columns)
        DataGridColumnPool().reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 100 }
        )
        return (tableView, schema)
    }

    private func tableColumnIndex(of name: String, in grid: (tableView: NSTableView, schema: ColumnIdentitySchema)) -> Int? {
        guard let identifier = grid.schema.identifier(for: grid.schema.dataIndex(forColumnName: name) ?? -1) else {
            return nil
        }
        let index = grid.tableView.column(withIdentifier: identifier)
        return index >= 0 ? index : nil
    }

    @Test("A data column does not sit one place after its data index")
    func dataColumnsAreNotOffsetByOne() throws {
        let grid = makeGrid(columns: ["id", "name", "customer_id"])
        let tableColumn = try #require(tableColumnIndex(of: "customer_id", in: grid))

        let resolved = DataGridView.dataColumnIndex(for: tableColumn, in: grid.tableView, schema: grid.schema)

        #expect(resolved == 2)
        #expect(tableColumn - 1 != resolved, "the subtract-one mapping is what shipped broken")
    }

    @Test("Every data column resolves back to its own index")
    func everyColumnRoundTrips() throws {
        let names = ["id", "name", "customer_id", "total"]
        let grid = makeGrid(columns: names)

        for (dataIndex, name) in names.enumerated() {
            let tableColumn = try #require(tableColumnIndex(of: name, in: grid))
            #expect(DataGridView.dataColumnIndex(for: tableColumn, in: grid.tableView, schema: grid.schema) == dataIndex)
        }
    }

    @Test("Reordering a column moves it without changing what it resolves to")
    func reorderingKeepsTheMapping() throws {
        let grid = makeGrid(columns: ["id", "name", "customer_id"])
        let before = try #require(tableColumnIndex(of: "customer_id", in: grid))

        grid.tableView.moveColumn(before, toColumn: DataGridView.firstDataTableColumnIndex)
        let after = try #require(tableColumnIndex(of: "customer_id", in: grid))

        #expect(after != before)
        #expect(DataGridView.dataColumnIndex(for: after, in: grid.tableView, schema: grid.schema) == 2)
    }

    @Test("The row-number column is not a data column")
    func rowNumberColumnIsNotData() {
        let grid = makeGrid(columns: ["id", "name"])
        #expect(DataGridView.isDataTableColumn(0) == false)
        #expect(DataGridView.dataColumnIndex(for: 0, in: grid.tableView, schema: grid.schema) == nil)
    }
}
