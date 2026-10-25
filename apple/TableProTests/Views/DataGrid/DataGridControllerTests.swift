//
//  DataGridControllerTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DataGridControllerTests {
    private func cell(_ row: Int, _ column: Int) -> GridSelection {
        GridSelectionReducer.single(GridCoord(row: row, displayColumn: column))
    }

    private func reordered(_ table: TableRows, ids: [Int]) -> TableRows {
        var rows = table
        rows.reorderRows(ContiguousArray(ids.compactMap { table.row(withID: .existing($0)) }))
        return rows
    }

    private func deletingGrid() -> HostedDataGrid {
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        configuration.commands = [.deleteRows]
        return HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration)
    }

    // What AppKit does with a heading click before it calls sortDescriptorsDidChange: it reports the press, then
    // puts the clicked key first (flipped when it already was), or under Option appends it or flips it in place.
    private func clickHeading(_ column: NSTableColumn, in grid: HostedDataGrid, modifiers: NSEvent.ModifierFlags = []) throws {
        grid.setCurrentEventModifiers(modifiers)
        let addsKey = modifiers.contains(.option)
        try #require(NSApp.currentEvent?.modifierFlags.contains(.option) == addsKey)
        let prototype = try #require(column.sortDescriptorPrototype)
        grid.controller.tableView(grid.main, mouseDownInHeaderOf: column)
        var descriptors = grid.main.sortDescriptors
        if let existing = descriptors.firstIndex(where: { $0.key == prototype.key }) {
            let flipped = NSSortDescriptor(key: prototype.key, ascending: !descriptors[existing].ascending)
            if addsKey {
                descriptors[existing] = flipped
            } else {
                descriptors.remove(at: existing)
                descriptors.insert(existing == 0 ? flipped : prototype, at: 0)
            }
        } else if addsKey {
            descriptors.append(prototype)
        } else {
            descriptors.insert(prototype, at: 0)
        }
        grid.main.sortDescriptors = descriptors
    }

    private func sortedNames(_ grid: HostedDataGrid) -> [String?] {
        grid.model.store.sortState.columns.map { $0.columnName }
    }

    // MARK: - Keyboard

    @Test("Typing a letter selects the next row whose active column starts with it")
    func typeSelectMovesTheRow() async throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.focus()
        grid.model.setSelection(cell(0, 1))

        try #require(grid.press("d", keyCode: KeyCode.d.rawValue))

        try await waitUntil(timeout: .seconds(2)) { grid.model.selection.activeCell?.row == 3 }
        #expect(grid.model.selectedRowIDs == [.existing(3)])
        #expect(grid.model.activeCell?.column.name == "name")
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 3))
    }

    @Test("Delete with Caps Lock on reaches the delete command")
    func deleteWithCapsLockDeletesRows() throws {
        let grid = deletingGrid()
        defer { grid.close() }
        grid.focus()
        grid.model.selectRows([.existing(1), .existing(2)])

        try #require(grid.press("\u{7F}", keyCode: KeyCode.delete.rawValue, modifiers: [.capsLock]))

        #expect(grid.owner.deleteRequests == [[.existing(1), .existing(2)]])
    }

    @Test("Forward Delete, Fn and Caps Lock included, reaches the delete command")
    func forwardDeleteDeletesRows() throws {
        let grid = deletingGrid()
        defer { grid.close() }
        grid.focus()
        grid.model.selectRows([.existing(3)])

        try #require(grid.press("\u{F728}", keyCode: KeyCode.forwardDelete.rawValue, modifiers: [.function, .capsLock]))

        #expect(grid.owner.deleteRequests == [[.existing(3)]])
    }

    @Test("Shift-Space widens a cell range to the whole rows it touches")
    func shiftSpaceWidensToRows() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.focus()
        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(rows: 1...2, columns: 1...1)],
            activeCell: GridCoord(row: 2, displayColumn: 1),
            anchor: GridCoord(row: 1, displayColumn: 1)
        ))

        try #require(grid.press(" ", keyCode: KeyCode.space.rawValue, modifiers: [.shift, .capsLock]))

        #expect(grid.model.selection.rectangles == [GridRect(rows: 1...2, columns: 0...2)])
        #expect(grid.model.selection.activeCell?.displayColumn == 1)
    }

    @Test("Space sets every selected checkbox the same way and leaves the selection where it was")
    func spaceTogglesCheckboxes() throws {
        var configuration = DataGridConfiguration()
        configuration.checkboxColumns = [0]
        let grid = HostedDataGrid(rows: GridFixtureRows.people, configuration: configuration) { owner, _ in
            owner.checkboxStates = [.existing(1): true, .existing(2): false]
        }
        defer { grid.close() }
        grid.focus()
        grid.model.selectRows([.existing(1), .existing(2)])
        let selected = grid.model.selection

        try #require(grid.press(" ", keyCode: KeyCode.space.rawValue))

        #expect(grid.owner.checkboxWrites.count == 1)
        #expect(grid.owner.checkboxWrites.first?.isOn == true)
        #expect(grid.owner.checkboxWrites.first?.rowIDs == [.existing(1), .existing(2)])
        #expect(grid.owner.checkboxWrites.first?.column == "id")
        #expect(grid.model.selection == selected)
    }

    // MARK: - Header

    @Test("A plain heading click sorts by that column alone and an Option-click adds a key")
    func headingClicksReplaceAndOptionAdds() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))

        try clickHeading(name, in: grid)
        #expect(sortedNames(grid) == ["name"])

        try clickHeading(age, in: grid, modifiers: .option)
        #expect(sortedNames(grid) == ["name", "age"])
        #expect(grid.model.store.sortState.columns.map { $0.direction } == [.ascending, .ascending])
        #expect(grid.main.sortDescriptors.map { $0.key } == ["name", "age"].map { DataGridColumnID(name: $0, occurrence: 0).stringValue })

        try clickHeading(age, in: grid)
        #expect(sortedNames(grid) == ["age"])
        #expect(grid.model.store.sortState.source == .user)
        #expect(grid.main.sortDescriptors.map { $0.key } == [DataGridColumnID(name: "age", occurrence: 0).stringValue])
        #expect(grid.owner.sortChanges.count == 3)
    }

    @Test("A plain click on the sorted heading flips it and an Option-click on a secondary key flips only that key")
    func headingClicksFlip() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let name = try #require(grid.tableColumn(named: "name"))
        let age = try #require(grid.tableColumn(named: "age"))

        try clickHeading(name, in: grid)
        try clickHeading(name, in: grid)
        #expect(grid.model.store.sortState.columns.map { $0.direction } == [.descending])

        try clickHeading(age, in: grid, modifiers: .option)
        try clickHeading(age, in: grid, modifiers: .option)
        #expect(sortedNames(grid) == ["name", "age"])
        #expect(grid.model.store.sortState.columns.map { $0.direction } == [.descending, .descending])
    }

    // MARK: - Columns

    @Test("Moving a column in the header keeps the cursor on that column")
    func columnReorderKeepsCursor() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(cell(1, 2))
        let age = try #require(grid.tableIndex(ofDisplayPosition: 2))
        let id = try #require(grid.tableIndex(ofDisplayPosition: 0))

        grid.main.moveColumn(age, toColumn: id)

        #expect(grid.model.columns.orderedNames == ["age", "id", "name"])
        #expect(grid.model.selection.activeCell == GridCoord(row: 1, displayColumn: 0))
        #expect(grid.model.activeCell?.column.name == "age")
        #expect(grid.model.activeCell?.rowID == .existing(1))
        #expect(grid.model.store.columnLayout.columnOrder == ["age", "id", "name"])
    }

    // MARK: - Find

    @Test("A find match moves the active cell to the match's column, so the arrow keys continue from it")
    func findMatchSetsActiveColumn() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(cell(0, 0))

        grid.model.showFind()
        grid.model.find.term = "dee"
        grid.model.findQueryDidChange()

        #expect(grid.model.selection.activeCell == GridCoord(row: 3, displayColumn: 1))
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 3))

        grid.main.moveRight(nil)

        #expect(grid.model.selection.activeCell == GridCoord(row: 3, displayColumn: 2))
    }

    // MARK: - Frozen pane

    @Test("The frozen pane lies over the main table's leading columns, at the same geometry")
    func frozenPaneCoversLeadingColumns() throws {
        var layout = ColumnLayoutState()
        layout.frozenColumnCount = 2
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(), store: InMemoryDataGridStateStore(columnLayout: layout))
        defer { grid.close() }

        #expect(grid.controller.effectiveFrozenCount == 2)
        #expect(!grid.frozenScrollView.isHidden)
        #expect(grid.frozen.tableColumns.count == 3)
        #expect(grid.frozen.tableColumns.first?.identifier == DataGridPane.rowNumberIdentifier)
        for index in 0..<grid.frozen.tableColumns.count {
            let shown = grid.frozen.rect(ofColumn: index)
            let home = grid.main.rect(ofColumn: index)
            #expect(shown.minX == home.minX)
            #expect(shown.width == home.width)
        }
        let frame = grid.frozenScrollView.frame
        #expect(frame.minX == 0)
        #expect(frame.minY == grid.mainScrollView.frame.minY)
        #expect(frame.width == grid.container.frozenPaneWidth)
        #expect(frame.width == grid.controller.frozen.columnsWidth)
        #expect(frame.height == grid.container.bounds.height - grid.mainScrollView.legacyHorizontalScrollerHeight)
    }

    @Test("The two panes scroll vertically in step, and the frozen pane never scrolls sideways")
    func panesScrollInStep() async throws {
        var layout = ColumnLayoutState()
        layout.frozenColumnCount = 1
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(), store: InMemoryDataGridStateStore(columnLayout: layout))
        defer { grid.close() }
        let mainClip = grid.mainScrollView.contentView
        let frozenClip = grid.frozenScrollView.contentView

        grid.main.scroll(NSPoint(x: 300, y: grid.main.rect(ofRow: 30).minY))

        try await waitUntil(timeout: .seconds(2)) { frozenClip.bounds.origin.y == mainClip.bounds.origin.y }
        #expect(mainClip.bounds.origin.x > 0)
        #expect(frozenClip.bounds.origin.x == 0)

        grid.frozen.scroll(NSPoint(x: 0, y: grid.frozen.rect(ofRow: 10).minY))

        try await waitUntil(timeout: .seconds(2)) { mainClip.bounds.origin.y == frozenClip.bounds.origin.y }
        #expect(frozenClip.bounds.origin.x == 0)
    }

    @Test("Both panes emphasize their selected rows together and stop together")
    func panesEmphasizeTogether() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.selectRows([.existing(1)])
        let mainRow = try #require(grid.main.rowView(atRow: 1, makeIfNecessary: true))
        let frozenRow = try #require(grid.frozen.rowView(atRow: 1, makeIfNecessary: true))
        #expect(!grid.frozenScrollView.isHidden)

        grid.focus()

        #expect(grid.container.gridHasFocus)
        #expect(mainRow.isSelected)
        #expect(frozenRow.isSelected)
        #expect(mainRow.isEmphasized)
        #expect(frozenRow.isEmphasized)

        grid.setKeyWindow(false)

        #expect(!grid.container.gridHasFocus)
        #expect(!mainRow.isEmphasized)
        #expect(!frozenRow.isEmphasized)
    }

    // MARK: - Accessibility

    @Test("A cell's label names the row number on screen and the column's display position")
    func accessibilityLabelsUseScreenPositions() throws {
        let wasActive = DataGridAccessibility.isActive
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = wasActive }
        var layout = ColumnLayoutState()
        layout.columnOrder = ["age", "id", "name"]
        let grid = HostedDataGrid(
            rows: GridFixtureRows.people,
            store: InMemoryDataGridStateStore(columnLayout: layout)
        ) { owner, _ in
            owner.rowNumberOffset = 100
        }
        defer { grid.close() }
        grid.model.setValueFilter(GridFixtureRows.nameFilter(["bob", "dee"]))
        grid.layout()

        let index = try #require(grid.tableIndex(ofDisplayPosition: 2))
        let cell = try #require(grid.main.view(atColumn: index, row: 1, makeIfNecessary: true) as? DataGridAccessibilityCellView)

        #expect(cell.accessibilityLabel() == "Row 102, column 3: dee")
        #expect(cell.accessibilityIdentifier() == "data-grid-cell")
        #expect(cell.accessibilityRowIndexRange() == NSRange(location: 1, length: 1))
        #expect(!grid.frozen.isAccessibilityElement())
        #expect(grid.frozenScrollView.accessibilityChildren()?.isEmpty == true)
    }

    // MARK: - Selection

    @Test("A reload keeps the model's selection in both tables, following its rows")
    func reloadKeepsSelection() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(rows: 1...2, columns: 0...2)],
            activeCell: GridCoord(row: 1, displayColumn: 1),
            anchor: GridCoord(row: 1, displayColumn: 1)
        ))
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 1...2))

        grid.model.reloadRows()

        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 1...2))
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integersIn: 1...2))

        grid.owner.tableRows = reordered(GridFixtureRows.people, ids: [4, 3, 2, 1, 0])
        grid.model.reloadRows()

        #expect(grid.model.selectedRowIDs == [.existing(2), .existing(1)])
        #expect(grid.model.activeCell?.rowID == .existing(1))
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 2...3))
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integersIn: 2...3))
    }

    @Test("A row the table selects itself becomes the model's selection, keeping the column")
    func nativeRowSelectionReachesModel() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(cell(1, 2))

        grid.main.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)

        #expect(grid.model.selection.activeCell == GridCoord(row: 4, displayColumn: 2))
        #expect(grid.model.selectedRowIDs == [.existing(4)])
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integer: 4))
    }
}
