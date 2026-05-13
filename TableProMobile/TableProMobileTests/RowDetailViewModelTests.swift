import Foundation
import Testing
import TableProDatabase
import TableProModels
@testable import TableProMobile

@MainActor
@Suite("RowDetailViewModel")
struct RowDetailViewModelTests {

    private func makeColumns() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
    }

    private func makeRows() -> [Row] {
        [
            Row(cells: [.text("1"), .text("Alice")]),
            Row(cells: [.text("2"), .text("Bob")])
        ]
    }

    private func makeSession(driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "test")
    }

    @Test("canEdit requires session, table, primary key, and not safe-mode-blocked")
    func canEditPreconditions() {
        let driver = MockDatabaseDriver()

        let withoutTable = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        #expect(withoutTable.canEdit == false, "no table → cannot edit")

        let blocked = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: .readOnly
        )
        #expect(blocked.canEdit == false, "read-only safe mode → cannot edit")

        let editable = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns(), safeModeLevel: .off
        )
        #expect(editable.canEdit == true)
    }

    @Test("startEditing populates editedValues from current row")
    func startEditingCopiesValues() {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )

        vm.startEditing()
        #expect(vm.isEditing == true)
        #expect(vm.editedValues == ["1", "Alice"])
    }

    @Test("cancelEditing clears edited values")
    func cancelEditingResets() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        vm.cancelEditing()
        #expect(vm.isEditing == false)
        #expect(vm.editedValues.isEmpty)
    }

    @Test("toggleNull flips between empty string and nil")
    func toggleNullFlips() {
        let vm = RowDetailViewModel(columns: makeColumns(), rows: makeRows(), initialIndex: 0)
        vm.startEditing()

        #expect(vm.editedValues[1] == "Alice")
        vm.toggleNull(at: 1)
        #expect(vm.editedValues[1] == nil)

        vm.toggleNull(at: 1)
        #expect(vm.editedValues[1] == "")
    }

    @Test("saveChanges with no changes early-returns true and exits edit mode")
    func saveNoChanges() async {
        let driver = MockDatabaseDriver()
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(vm.isEditing == false)
        #expect(driver.executedQueries.isEmpty, "no UPDATE should be issued when nothing changed")
    }

    @Test("saveChanges runs UPDATE with primary keys and modified columns only")
    func saveExecutesUpdate() async {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0))
        ]
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: makeColumns()
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 1)

        let success = await vm.saveChanges()
        #expect(success == true)
        #expect(driver.executedQueries.count == 1)
        let query = driver.executedQueries[0].uppercased()
        #expect(query.hasPrefix("UPDATE"))
        #expect(query.contains("WHERE"))
    }

    @Test("saveChanges fails when no primary key value present")
    func saveWithoutPrimaryKey() async {
        let driver = MockDatabaseDriver()
        let columnsNoPK: [ColumnInfo] = [
            ColumnInfo(name: "name", typeName: "TEXT", ordinalPosition: 0)
        ]
        let rows = [Row(cells: [.text("Alice")])]
        let vm = RowDetailViewModel(
            columns: columnsNoPK, rows: rows, initialIndex: 0,
            table: TableInfo(name: "users"), session: makeSession(driver: driver),
            columnDetails: columnsNoPK
        )
        vm.startEditing()
        vm.setEditedValue("Charlie", at: 0)

        let success = await vm.saveChanges()
        #expect(success == false)
        #expect(vm.operationError != nil)
    }

    @Test("loadFullValue populates override and clears loadingCell")
    func lazyLoadPopulates() async {
        let provider: (CellRef) async throws -> String? = { _ in "the full blob value" }
        let vm = RowDetailViewModel(
            columns: makeColumns(), rows: makeRows(), initialIndex: 0,
            table: TableInfo(name: "users"),
            loadFullValue: provider
        )
        let ref = CellRef(table: "users", column: "name", primaryKey: [.init(column: "id", value: "1")])

        await vm.loadFullValue(ref: ref, cellIndex: 1)
        #expect(vm.loadingCell == nil)
        #expect(vm.hasOverride(forRow: 0, cellIndex: 1) == true)
    }
}
