//
//  DataGridCellRegistryTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@MainActor
private final class StubAccessoryDelegate: DataGridCellAccessoryDelegate {
    func dataGridCellDidClickFKArrow(row: Int, columnIndex: Int) {}
    func dataGridCellDidClickChevron(row: Int, columnIndex: Int) {}
}

@Suite("DataGridCellRegistry.resolveKind")
@MainActor
struct DataGridCellRegistryResolveKindTests {
    @Test("Foreign key flag wins over every other signal")
    func resolveKind_returnsForeignKeyForFKColumn() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .boolean(rawType: nil),
            isFKColumn: true,
            isDropdownColumn: true
        )
        #expect(kind == .foreignKey)
    }

    @Test("Dropdown flag wins when not a foreign key")
    func resolveKind_returnsDropdownForDropdownColumn() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .json(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: true
        )
        #expect(kind == .dropdown)
    }

    @Test("Boolean column type resolves to boolean kind")
    func resolveKind_returnsBooleanForBooleanType() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .boolean(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: false
        )
        #expect(kind == .boolean)
    }

    @Test("Date, timestamp, and datetime column types all resolve to date kind")
    func resolveKind_returnsDateForDateLikeTypes() {
        let registry = DataGridCellRegistry()
        for type: ColumnType in [.date(rawType: nil), .timestamp(rawType: nil), .datetime(rawType: nil)] {
            let kind = registry.resolveKind(
                columnIndex: 0,
                columnType: type,
                isFKColumn: false,
                isDropdownColumn: false
            )
            #expect(kind == .date)
        }
    }

    @Test("JSON column type resolves to json kind")
    func resolveKind_returnsJsonForJsonType() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .json(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: false
        )
        #expect(kind == .json)
    }

    @Test("Blob column type resolves to blob kind")
    func resolveKind_returnsBlobForBlobType() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .blob(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: false
        )
        #expect(kind == .blob)
    }

    @Test("Plain text column resolves to text kind")
    func resolveKind_returnsTextForPlainTextColumn() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .text(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: false
        )
        #expect(kind == .text)
    }

    @Test("Nil column type resolves to text kind")
    func resolveKind_returnsTextWhenColumnTypeIsNil() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: nil,
            isFKColumn: false,
            isDropdownColumn: false
        )
        #expect(kind == .text)
    }

    @Test("FK takes priority over dropdown when both flags set")
    func resolveKind_priorityForeignKeyOverDropdown() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .text(rawType: nil),
            isFKColumn: true,
            isDropdownColumn: true
        )
        #expect(kind == .foreignKey)
    }

    @Test("Dropdown takes priority over typed columns")
    func resolveKind_priorityDropdownOverType() {
        let registry = DataGridCellRegistry()
        let kind = registry.resolveKind(
            columnIndex: 0,
            columnType: .blob(rawType: nil),
            isFKColumn: false,
            isDropdownColumn: true
        )
        #expect(kind == .dropdown)
    }
}

@Suite("DataGridCellRegistry.dequeueCell")
@MainActor
struct DataGridCellRegistryDequeueTests {
    private func makeTableView() -> NSTableView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(0))
        tableView.addTableColumn(column)
        return tableView
    }

    @Test("Text kind dequeues DataGridTextCellView")
    func dequeueCell_returnsTextSubclassForTextKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .text, in: makeTableView())
        #expect(cell is DataGridTextCellView)
        #expect(cell.identifier == DataGridTextCellView.reuseIdentifier)
    }

    @Test("Foreign key kind dequeues DataGridForeignKeyCellView")
    func dequeueCell_returnsForeignKeySubclassForFKKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .foreignKey, in: makeTableView())
        #expect(cell is DataGridForeignKeyCellView)
        #expect(cell.identifier == DataGridForeignKeyCellView.reuseIdentifier)
    }

    @Test("Dropdown kind dequeues DataGridDropdownCellView")
    func dequeueCell_returnsDropdownSubclassForDropdownKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .dropdown, in: makeTableView())
        #expect(cell is DataGridDropdownCellView)
        #expect(cell.identifier == DataGridDropdownCellView.reuseIdentifier)
    }

    @Test("Boolean kind dequeues DataGridBooleanCellView")
    func dequeueCell_returnsBooleanSubclassForBooleanKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .boolean, in: makeTableView())
        #expect(cell is DataGridBooleanCellView)
        #expect(cell.identifier == DataGridBooleanCellView.reuseIdentifier)
    }

    @Test("Date kind dequeues DataGridDateCellView")
    func dequeueCell_returnsDateSubclassForDateKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .date, in: makeTableView())
        #expect(cell is DataGridDateCellView)
        #expect(cell.identifier == DataGridDateCellView.reuseIdentifier)
    }

    @Test("JSON kind dequeues DataGridJsonCellView")
    func dequeueCell_returnsJsonSubclassForJsonKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .json, in: makeTableView())
        #expect(cell is DataGridJsonCellView)
        #expect(cell.identifier == DataGridJsonCellView.reuseIdentifier)
    }

    @Test("Blob kind dequeues DataGridBlobCellView")
    func dequeueCell_returnsBlobSubclassForBlobKind() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .blob, in: makeTableView())
        #expect(cell is DataGridBlobCellView)
        #expect(cell.identifier == DataGridBlobCellView.reuseIdentifier)
    }

    @Test("Reuse identifiers are distinct for every cell kind")
    func reuseIdentifiers_areDistinctPerKind() {
        let identifiers: [NSUserInterfaceItemIdentifier] = [
            DataGridTextCellView.reuseIdentifier,
            DataGridForeignKeyCellView.reuseIdentifier,
            DataGridDropdownCellView.reuseIdentifier,
            DataGridBooleanCellView.reuseIdentifier,
            DataGridDateCellView.reuseIdentifier,
            DataGridJsonCellView.reuseIdentifier,
            DataGridBlobCellView.reuseIdentifier,
        ]
        let unique = Set(identifiers.map(\.rawValue))
        #expect(unique.count == identifiers.count)
    }

    @Test("Freshly created cell receives accessoryDelegate from registry")
    func dequeueCell_propagatesAccessoryDelegateToFreshCell() {
        let registry = DataGridCellRegistry()
        let delegate = StubAccessoryDelegate()
        registry.accessoryDelegate = delegate

        let cell = registry.dequeueCell(of: .text, in: makeTableView())
        #expect(cell.accessoryDelegate === delegate)
    }

    @Test("Freshly created cell receives nullDisplayString from registry")
    func dequeueCell_propagatesNullDisplayStringToFreshCell() {
        let registry = DataGridCellRegistry()
        let cell = registry.dequeueCell(of: .text, in: makeTableView())
        #expect(cell.nullDisplayString == registry.nullDisplayString)
    }
}

@Suite("DataGridCellRegistry.makeRowNumberCell")
@MainActor
struct DataGridCellRegistryRowNumberTests {
    private func makeTableView() -> NSTableView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        tableView.addTableColumn(column)
        return tableView
    }

    @Test("Row number cell has RowNumberCellView identifier")
    func makeRowNumberCell_hasRowNumberCellViewIdentifier() {
        let registry = DataGridCellRegistry()
        let view = registry.makeRowNumberCell(
            in: makeTableView(),
            row: 0,
            cachedRowCount: 5,
            visualState: .empty
        )
        #expect(view.identifier?.rawValue == "RowNumberCellView")
    }

    @Test("Row number cell renders one-based row index")
    func makeRowNumberCell_rendersOneBasedRowIndex() {
        let registry = DataGridCellRegistry()
        let view = registry.makeRowNumberCell(
            in: makeTableView(),
            row: 4,
            cachedRowCount: 10,
            visualState: .empty
        )
        let cellView = view as? NSTableCellView
        #expect(cellView != nil)
        #expect(cellView?.textField?.stringValue == "5")
    }

    @Test("Row number cell renders empty string when row is out of cached range")
    func makeRowNumberCell_rendersEmptyWhenRowOutOfRange() {
        let registry = DataGridCellRegistry()
        let view = registry.makeRowNumberCell(
            in: makeTableView(),
            row: 99,
            cachedRowCount: 5,
            visualState: .empty
        )
        let cellView = view as? NSTableCellView
        #expect(cellView != nil)
        #expect(cellView?.textField?.stringValue == "")
    }
}
