//
//  DataGridPaneTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridPaneTests {
    private func dataColumnNames(_ grid: HostedDataGrid, in kind: DataGridPane.Kind = .main) -> [String] {
        let pane = grid.controller.container.pane(kind)
        return pane.tableView.tableColumns.compactMap { pane.columnID(of: $0)?.name }
    }

    private func hasAttachment(_ title: NSAttributedString) -> Bool {
        var found = false
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    private func frozenGrid(count: Int) -> HostedDataGrid {
        var layout = ColumnLayoutState()
        layout.frozenColumnCount = count
        return HostedDataGrid(rows: GridFixtureRows.wide(), store: InMemoryDataGridStateStore(columnLayout: layout))
    }

    // MARK: - Columns

    @Test("A new page of the same columns keeps the same table columns, so nothing flickers (#951)")
    func sameColumnsReuseTableColumns() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let before = grid.main.tableColumns.map { ObjectIdentifier($0) }

        grid.owner.tableRows = TableRows.from(
            queryRows: [["7", "fay", "20"], ["8", "gus", "61"]],
            columns: ["id", "name", "age"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .integer(rawType: "INT")]
        )
        grid.model.reloadRows()

        #expect(grid.main.tableColumns.map { ObjectIdentifier($0) } == before)
        #expect(grid.main.numberOfRows == 2)
    }

    @Test("The row-number column leads the main table and can be neither moved nor displaced")
    func rowNumberColumnStaysFirst() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        #expect(grid.main.tableColumns.first?.identifier == DataGridPane.rowNumberIdentifier)
        #expect(dataColumnNames(grid) == ["id", "name", "age"])
        #expect(!grid.controller.tableView(grid.main, shouldReorderColumn: 0, toColumn: 2))
        #expect(!grid.controller.tableView(grid.main, shouldReorderColumn: 2, toColumn: 0))
        #expect(grid.controller.tableView(grid.main, shouldReorderColumn: 1, toColumn: 3))
    }

    @Test("A grid without row numbers shows no row-number column and hides the empty frozen pane")
    func noRowNumbersHidesFrozenPane() {
        var configuration = DataGridConfiguration()
        configuration.showRowNumbers = false
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { grid.close() }

        #expect(grid.main.tableColumns.first?.identifier != DataGridPane.rowNumberIdentifier)
        #expect(grid.frozen.tableColumns.isEmpty)
        #expect(grid.frozenScrollView.isHidden)
        #expect(grid.container.frozenPaneWidth == 0)
    }

    @Test("A hidden column is not presented, and showing it puts it back in its place")
    func hiddenColumnIsNotPresented() {
        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["name"]
        let grid = HostedDataGrid(rows: GridFixtureRows.people, store: InMemoryDataGridStateStore(columnLayout: layout))
        defer { grid.close() }

        #expect(dataColumnNames(grid) == ["id", "age"])

        grid.model.updateColumnLayout { $0.hiddenColumns = [] }

        #expect(dataColumnNames(grid) == ["id", "name", "age"])
    }

    @Test("A column named in the minimum widths gets that floor and the others keep the default")
    func minimumWidthIsAFloor() throws {
        var configuration = DataGridConfiguration()
        configuration.columnMinimumWidths = ["id": 200]
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { grid.close() }
        let id = try #require(grid.tableColumn(named: "id"))
        let name = try #require(grid.tableColumn(named: "name"))

        #expect(id.minWidth == 200)
        #expect(id.width >= 200)
        #expect(name.minWidth == DataGridMetrics.dataColumnMinWidth)
        #expect(name.maxWidth == DataGridMetrics.dataColumnMaxWidth)
    }

    @Test("Each data column sorts by its column ID, and a grid that cannot sort gets no sort prototype")
    func sortPrototypes() {
        let repeated = TableRows.from(
            queryRows: [["1", "2"]],
            columns: ["id", "id"],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")]
        )
        let sorting = HostedDataGrid(rows: repeated)
        defer { sorting.close() }
        let keys = sorting.main.tableColumns.compactMap { $0.sortDescriptorPrototype?.key }
        #expect(keys == ["id", "id#1"])

        var configuration = DataGridConfiguration()
        configuration.supportsColumnSort = false
        let unsorted = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
        defer { unsorted.close() }
        #expect(unsorted.main.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })
    }

    @Test("The main table runs past its last column by the trailing space")
    func trailingSpaceIsPartOfTheTable() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide())
        defer { grid.close() }
        let last = try #require(grid.main.tableColumns.indices.last)

        #expect(grid.main.frame.width >= grid.main.rect(ofColumn: last).maxX + DataGridMetrics.trailingSpace)
    }

    // MARK: - Header

    @Test("A heading's tooltip names its type and the sort order once several keys sort")
    func headingToolTip() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))
        #expect(name.headerToolTip == "name (TEXT)")

        grid.model.setSort(SortState(
            columns: [
                SortColumn(columnIndex: 1, direction: .ascending, columnName: "name"),
                SortColumn(columnIndex: 2, direction: .descending, columnName: "age"),
            ],
            source: .user
        ))

        #expect(name.headerToolTip?.hasPrefix("name (TEXT)\n") == true)
        #expect(age.headerToolTip?.hasPrefix("age (INT)\n") == true)
        #expect(name.headerCell.accessibilitySortDirection() == .ascending)
        #expect(age.headerCell.accessibilitySortDirection() == .descending)
        #expect(grid.tableColumn(named: "id")?.headerCell.accessibilitySortDirection() == .unknown)
    }

    @Test("A value-filtered column carries the filter symbol in its title")
    func filteredHeadingShowsSymbol() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))
        #expect(!hasAttachment(name.headerCell.attributedStringValue))

        grid.model.setValueFilter(GridFixtureRows.nameFilter(["bob"]))

        #expect(hasAttachment(name.headerCell.attributedStringValue))
        #expect(name.headerCell.attributedStringValue.string.hasPrefix("name"))
        #expect(!hasAttachment(age.headerCell.attributedStringValue))
    }

    @Test("Command-clicking a heading selects its whole column and highlights the heading")
    func commandClickSelectsColumn() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))

        grid.setCurrentEventModifiers(.command)
        grid.controller.tableView(grid.main, didClick: name)

        #expect(grid.model.selection.columns == IndexSet(integer: 1))
        #expect(grid.model.selection.rectangles == [GridRect(rows: 0...4, columns: 1...1)])
        #expect(grid.main.highlightedTableColumn === name)
        #expect(grid.model.store.sortState.columns.isEmpty)
    }

    // MARK: - Frozen pane

    @Test("Frozen columns that would cover more than two thirds of the grid scroll with the rest")
    func frozenColumnsAreCapped() {
        let grid = frozenGrid(count: 6)
        defer { grid.close() }

        #expect(grid.model.columns.frozenCount == 6)
        #expect(grid.controller.effectiveFrozenCount < 6)
        #expect(grid.container.frozenPaneWidth <= grid.container.bounds.width * DataGridMetrics.maximumFrozenShare)
        #expect(grid.controller.canFreezeColumns(throughDisplayPosition: 0))
        #expect(!grid.controller.canFreezeColumns(throughDisplayPosition: 6))
    }

    @Test("Freezing and unfreezing rebuild the frozen pane from the column set")
    func freezeAndUnfreeze() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide())
        defer { grid.close() }
        #expect(dataColumnNames(grid, in: .frozen).isEmpty)

        grid.model.updateColumnLayout { $0.frozenColumnCount = 2 }
        grid.layout()

        #expect(dataColumnNames(grid, in: .frozen) == ["c0", "c1"])
        #expect(dataColumnNames(grid).prefix(3) == ["c0", "c1", "c2"])

        grid.model.updateColumnLayout { $0.frozenColumnCount = 0 }
        grid.layout()

        #expect(dataColumnNames(grid, in: .frozen).isEmpty)
        #expect(grid.frozen.tableColumns.count == 1)
    }

    @Test("Revealing a column scrolled under the frozen pane brings it out beside the pane")
    func revealClearsFrozenPane() throws {
        let grid = frozenGrid(count: 1)
        defer { grid.close() }
        let clip = grid.mainScrollView.contentView
        grid.main.scroll(NSPoint(x: grid.main.frame.width, y: 0))
        #expect(clip.bounds.minX > 0)

        grid.controller.revealColumn(2)

        let index = try #require(grid.tableIndex(ofDisplayPosition: 2))
        let column = grid.main.rect(ofColumn: index)
        let tolerance = 1 / grid.window.backingScaleFactor
        #expect(column.minX >= clip.bounds.minX + grid.container.frozenPaneWidth - tolerance)
        #expect(column.maxX <= clip.bounds.maxX + tolerance)
    }

    // MARK: - Rows

    @Test("A row view reports the row it shows after rows above it are removed or inserted")
    func rowViewFollowsItsRow() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let rowView = try #require(grid.main.rowView(atRow: 3, makeIfNecessary: true) as? DataGridRowView)
        #expect(rowView.rowIndex == 3)

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(0)]))
        #expect(grid.main.numberOfRows == 4)
        #expect(grid.frozen.numberOfRows == 4)
        #expect(rowView.rowIndex == 2)

        grid.model.apply(grid.owner.tableRows.insertInsertedRow(at: 0, values: ["9", "new", "1"]))
        #expect(grid.main.numberOfRows == 5)
        #expect(grid.frozen.numberOfRows == 5)
        #expect(rowView.rowIndex == 3)
    }

    @Test("A row height change reaches both panes")
    func rowHeightReachesBothPanes() {
        let grid = frozenGrid(count: 1)
        defer { grid.close() }

        #expect(grid.main.rowHeight == grid.frozen.rowHeight)
        #expect(grid.main.rowHeight >= CGFloat(AppSettingsManager.shared.dataGrid.rowHeight.rawValue))
        #expect(grid.main.rect(ofRow: 40).minY == grid.frozen.rect(ofRow: 40).minY)
    }
}
