//
//  DataGridColumnWidthTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridColumnWidthTests {
    private static let longValue = String(repeating: "M", count: 20)

    private static func rows(
        _ columns: [String],
        types: [ColumnType]? = nil,
        value: String = longValue,
        rowCount: Int = 1,
        foreignKeys: [String: ForeignKeyInfo] = [:]
    ) -> TableRows {
        TableRows.from(
            queryRows: (0..<rowCount).map { _ in columns.map { _ in PluginCellValue.text(value) } },
            columns: columns,
            columnTypes: types ?? Array(repeating: .text(rawType: "TEXT"), count: columns.count),
            columnForeignKeys: foreignKeys,
            foreignKeysFetched: !foreignKeys.isEmpty
        )
    }

    private static func editable() -> DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        return configuration
    }

    // A drag on the divider: AppKit sets the width, then reports the resize.
    private func resize(_ column: NSTableColumn, to width: CGFloat, in grid: HostedDataGrid) {
        let oldWidth = column.width
        column.width = width
        grid.controller.tableViewColumnDidResize(Notification(
            name: NSTableView.columnDidResizeNotification,
            object: grid.main,
            userInfo: ["NSTableColumn": column, "NSOldWidth": oldWidth]
        ))
    }

    private func width(of name: String, in grid: HostedDataGrid) throws -> CGFloat {
        try #require(grid.tableColumn(named: name)).width
    }

    private func applyMetadata(
        to grid: HostedDataGrid,
        foreignKeys: [String: ForeignKeyInfo]? = nil,
        enumValues: [String: [String]]? = nil
    ) {
        let delta = grid.owner.tableRows.updateDisplayMetadata(
            columnForeignKeys: foreignKeys,
            columnEnumValues: enumValues
        )
        grid.model.apply(delta)
    }

    // MARK: - Ownership

    @Test("Automatic widths stay out of the saved layout")
    func automaticWidthsStayOutOfTheLayout() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        #expect(grid.model.store.columnLayout.columnWidths.isEmpty)
        #expect(grid.model.store.columnLayout.columnContentWidths == nil)
    }

    @Test("A resize the reader makes is saved as a width they own")
    func userResizeTakesOwnership() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "name"))
        let target = column.width + 60

        resize(column, to: target, in: grid)

        let layout = grid.model.store.columnLayout
        #expect(layout.columnWidths == ["name": target])
        #expect(layout.columnContentWidths == ["name": target])
        #expect(try width(of: "name", in: grid) == target)
    }

    @Test("A resize of the row-number column saves nothing")
    func rowNumberResizeIsIgnored() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let rowNumbers = try #require(grid.main.tableColumns.first { $0.identifier == DataGridPane.rowNumberIdentifier })

        grid.controller.tableViewColumnDidResize(Notification(
            name: NSTableView.columnDidResizeNotification,
            object: grid.main,
            userInfo: ["NSTableColumn": rowNumbers, "NSOldWidth": rowNumbers.width - 10]
        ))

        #expect(grid.model.store.columnLayout.columnWidths.isEmpty)
    }

    @Test("A new result measured by the grid takes no ownership")
    func newResultMeasuresWithoutOwnership() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }

        grid.owner.tableRows = Self.rows(["code", "label"])
        grid.model.reloadRows()

        #expect(grid.model.store.columnLayout.columnWidths.isEmpty)
        #expect(grid.tableColumn(named: "code") != nil)
    }

    @Test("Hiding, showing and moving columns keeps the widths the reader sees")
    func widthsSurviveHideShowAndMove() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let nameWidth = try width(of: "name", in: grid)
        let idWidth = try width(of: "id", in: grid)

        grid.model.updateColumnLayout { $0.hiddenColumns = ["id"] }
        #expect(grid.tableColumn(named: "id") == nil)
        #expect(try width(of: "name", in: grid) == nameWidth)

        grid.model.updateColumnLayout { $0.hiddenColumns = [] }
        grid.model.updateColumnLayout { $0.columnOrder = ["age", "name", "id"] }

        #expect(try width(of: "name", in: grid) == nameWidth)
        #expect(try width(of: "id", in: grid) == idWidth)
        #expect(grid.model.store.columnLayout.columnWidths.isEmpty)
    }

    @Test("A reload over the same columns keeps the widths it measured")
    func sameColumnsKeepTheirWidths() throws {
        let grid = HostedDataGrid(rows: Self.rows(["note"], value: "short"))
        defer { grid.close() }
        let measured = try width(of: "note", in: grid)

        grid.owner.tableRows = Self.rows(["note"], value: String(repeating: "W", count: 45))
        grid.model.reloadRows()

        #expect(try width(of: "note", in: grid) == measured)
    }

    @Test("Columns whose rows land after them are measured again once the rows arrive")
    func rowsArrivingLateMeasureAgain() throws {
        let grid = HostedDataGrid(rows: Self.rows(["note"], rowCount: 0))
        defer { grid.close() }
        let headingOnly = try width(of: "note", in: grid)

        grid.owner.tableRows = Self.rows(["note"], value: String(repeating: "W", count: 45))
        grid.model.reloadRows()

        #expect(try width(of: "note", in: grid) > headingOnly)
    }

    @Test("Reset gives a column the reader sized back its automatic width")
    func resetReturnsToAutomaticWidth() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "name"))
        let automatic = column.width
        resize(column, to: automatic + 80, in: grid)
        try #require(grid.model.store.columnLayout.columnWidths["name"] == automatic + 80)

        grid.model.updateColumnLayout { $0.resetGeometry() }

        #expect(grid.model.store.columnLayout.columnWidths.isEmpty)
        #expect(try width(of: "name", in: grid) == automatic)
    }

    // MARK: - Saved widths

    @Test("A width the reader set is applied as saved, before and after its accessory is known")
    func ownedWidthIgnoresTheAccessory() throws {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["parent_id": 200]
        layout.columnContentWidths = ["parent_id": 200]
        let grid = HostedDataGrid(
            rows: Self.rows(["parent_id"]),
            store: InMemoryDataGridStateStore(columnLayout: layout)
        )
        defer { grid.close() }
        #expect(try width(of: "parent_id", in: grid) == 200)

        applyMetadata(to: grid, foreignKeys: ["parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id")])

        #expect(grid.controller.presenter.presentation(forDataIndex: 0).accessory == .foreignKey)
        #expect(try width(of: "parent_id", in: grid) == 200)

        applyMetadata(to: grid, foreignKeys: [:])

        #expect(try width(of: "parent_id", in: grid) == 200)
        #expect(grid.model.store.columnLayout.columnWidths == ["parent_id": 200])
    }

    // A layout saved before widths recorded who set them cannot tell a measured width from a dragged one.
    @Test("A legacy width widens when its column's accessory arrives after the restore")
    func legacyWidthWidensForALateAccessory() throws {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["parent_id": 168, "plain": 210]
        let grid = HostedDataGrid(
            rows: Self.rows(["parent_id", "plain"]),
            store: InMemoryDataGridStateStore(columnLayout: layout)
        )
        defer { grid.close() }
        #expect(try width(of: "parent_id", in: grid) == 168)

        applyMetadata(to: grid, foreignKeys: ["parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id")])

        #expect(grid.controller.presenter.presentation(forDataIndex: 0).accessory == .foreignKey)
        #expect(try width(of: "parent_id", in: grid) > 168)
        #expect(try width(of: "plain", in: grid) == 210)
    }

    @Test("Columns that share a name take the one width saved for it")
    func duplicateNamesShareTheSavedWidth() {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["result": 160]
        let grid = HostedDataGrid(
            rows: Self.rows(["result", "result"], types: [.text(rawType: "TEXT"), .date(rawType: "DATE")]),
            store: InMemoryDataGridStateStore(columnLayout: layout)
        )
        defer { grid.close() }

        let widths = grid.main.tableColumns
            .filter { grid.controller.main.columnID(of: $0)?.name == "result" }
            .map { $0.width }
        #expect(widths == [160, 160])
    }

    // MARK: - Accessories arriving late

    @Test("Late foreign key metadata widens an automatic column and leaves a sized one alone")
    func lateForeignKeyWidensAutomaticColumnOnly() throws {
        let grid = HostedDataGrid(rows: Self.rows(["id", "parent_id"]))
        defer { grid.close() }
        let idColumn = try #require(grid.tableColumn(named: "id"))
        resize(idColumn, to: 75, in: grid)
        let before = try width(of: "parent_id", in: grid)

        applyMetadata(to: grid, foreignKeys: ["parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id")])

        let widened = try width(of: "parent_id", in: grid)
        #expect(grid.controller.presenter.presentation(forDataIndex: 1).accessory == .foreignKey)
        #expect(try width(of: "id", in: grid) == 75)
        #expect(widened > before)
        #expect(
            DataGridCellAccessory.foreignKey.availableTextWidth(in: NSRect(x: 0, y: 0, width: widened, height: 24))
                >= CGFloat(Self.longValue.count) * ThemeEngine.shared.dataGridFonts.monoCharWidth
        )

        applyMetadata(to: grid, foreignKeys: [:])

        #expect(try width(of: "id", in: grid) == 75)
        #expect(try width(of: "parent_id", in: grid) == widened)
        #expect(grid.model.store.columnLayout.columnWidths == ["id": 75])
    }

    @Test("Late enum values widen the automatic column they appear in")
    func lateEnumValuesWidenTheirColumn() throws {
        let grid = HostedDataGrid(rows: Self.rows(["status"]), configuration: Self.editable())
        defer { grid.close() }
        let before = try width(of: "status", in: grid)

        applyMetadata(to: grid, enumValues: ["status": ["open", "closed"]])

        let widened = try width(of: "status", in: grid)
        #expect(grid.controller.presenter.presentation(forDataIndex: 0).kind == .dropdown)
        #expect(widened > before)
        #expect(
            DataGridCellAccessory.chevron.availableTextWidth(in: NSRect(x: 0, y: 0, width: widened, height: 24))
                >= CGFloat(Self.longValue.count) * ThemeEngine.shared.dataGridFonts.monoCharWidth
        )

        applyMetadata(to: grid, enumValues: [:])

        #expect(grid.controller.presenter.presentation(forDataIndex: 0).kind == .text)
        #expect(try width(of: "status", in: grid) == widened)
    }

    @Test("A column that loses its accessory keeps the width the reader gave it")
    func losingAnAccessoryKeepsTheWidth() throws {
        let grid = HostedDataGrid(
            rows: Self.rows(["created_at"], types: [.date(rawType: "DATE")], value: "2026-08-17"),
            configuration: Self.editable()
        )
        defer { grid.close() }
        #expect(grid.controller.presenter.presentation(forDataIndex: 0).accessory == .chevron)
        let column = try #require(grid.tableColumn(named: "created_at"))
        resize(column, to: 176, in: grid)

        grid.model.configuration.isEditable = false

        #expect(grid.controller.presenter.presentation(forDataIndex: 0).accessory == .none)
        #expect(try width(of: "created_at", in: grid) == 176)
        #expect(grid.model.store.columnLayout.columnWidths == ["created_at": 176])
    }

    // MARK: - Size to fit

    @Test("A divider double-click measures each column with its own accessory")
    func dividerFitCountsTheAccessory() throws {
        let rows = Self.rows(
            ["plain", "created_at", "parent_id"],
            types: [.text(rawType: "TEXT"), .date(rawType: "DATE"), .text(rawType: "TEXT")],
            foreignKeys: ["parent_id": TestFixtures.makeForeignKeyInfo(column: "parent_id")]
        )
        let grid = HostedDataGrid(rows: rows, configuration: Self.editable())
        defer { grid.close() }

        func fitted(_ position: Int) throws -> CGFloat {
            let index = try #require(grid.tableIndex(ofDisplayPosition: position))
            return grid.controller.tableView(grid.main, sizeToFitWidthOfColumn: index)
        }
        let plain = try fitted(0)
        let date = try fitted(1)
        let foreignKey = try fitted(2)

        #expect(date == plain + DataGridCellAccessory.chevron.reservedTrailingWidth)
        #expect(foreignKey == plain + DataGridCellAccessory.foreignKey.reservedTrailingWidth)
    }
}
