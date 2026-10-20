import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@MainActor
struct RowWriteRoutingTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "UInt64", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
        ColumnInfo(name: "name", typeName: "String", ordinalPosition: 1)
    ]

    private func session(_ plugin: StubPluginDriver, identity: RowIdentity = .everyColumn) -> ConnectionSession {
        let driver = PluginBackedDriver(plugin: plugin, dialedHosts: [], rowIdentity: identity, readsOnly: { _ in true })
        return ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "default")
    }

    @Test("Every-column identity locates a row only when every cell holds its full value")
    func everyColumnNeedsExactCells() {
        let exact = RowLocator.locate(
            cells: [.text("1"), .null], columns: columns, columnDetails: columns, identity: .everyColumn
        )
        let cut = RowLocator.locate(
            cells: [.text("1"), .truncatedText(prefix: "a", totalBytes: 9_000, ref: nil)],
            columns: columns, columnDetails: columns, identity: .everyColumn
        )
        let binary = RowLocator.locate(
            cells: [.text("1"), .binary(byteCount: 4, ref: nil)],
            columns: columns, columnDetails: columns, identity: .everyColumn
        )

        #expect(exact?.row == ["1", nil])
        #expect(exact?.keyValues == nil)
        #expect(cut == nil)
        #expect(binary == nil)
    }

    @Test("Key-column identity still needs a plain-text key, as before")
    func keyColumnsNeedTextKeys() {
        let located = RowLocator.locate(
            cells: [.text("1"), .truncatedText(prefix: "a", totalBytes: 9_000, ref: nil)],
            columns: columns, columnDetails: columns, identity: .keyColumns
        )

        #expect(located?.keyValues?.map { $0.value } == ["1"])
    }

    @Test("A row edit on an engine that writes its own rows goes to its writer with the row as read")
    func rowDetailSavesThroughTheWriter() async throws {
        let plugin = StubPluginDriver()
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("1"), .text("signup")])],
            initialIndex: 0,
            table: TableInfo(name: "events"),
            session: session(plugin),
            columnDetails: columns
        )
        vm.startEditing()
        vm.setEditedValue("purchase", at: 1)

        let saved = await vm.saveChanges()

        #expect(saved)
        let change = try #require(plugin.generatedChanges.first)
        #expect(change.type == .update)
        #expect(change.originalRow == ["1", "signup"])
        #expect(plugin.parameterizedQueries.map { $0.query } == ["WRITE update events"])
        #expect(plugin.plainQueries.isEmpty)
    }

    @Test("A row holding a cut-off value cannot be edited where rows are matched on every column")
    func cutOffRowIsReadOnly() {
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("1"), .truncatedText(prefix: "a", totalBytes: 9_000, ref: nil)])],
            initialIndex: 0,
            table: TableInfo(name: "events"),
            session: session(StubPluginDriver()),
            columnDetails: columns
        )

        #expect(vm.canEdit == false)
    }

    @Test("A delete on an engine that writes its own rows sends the whole row to its writer")
    func browserDeletesThroughTheWriter() async throws {
        let plugin = StubPluginDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: session(plugin), table: TableInfo(name: "events"), databaseType: .clickhouse, host: "localhost")

        let deleted = await vm.deleteRow(RowLocator(row: ["1", "signup"], keyValues: nil))

        #expect(deleted)
        let change = try #require(plugin.generatedChanges.first)
        #expect(change.type == .delete)
        #expect(change.originalRow == ["1", "signup"])
    }

    @Test("A row matched on every value is counted with the writer's own predicates before it changes")
    func identityIsCountedFirst() async throws {
        let plugin = StubPluginDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: session(plugin), table: TableInfo(name: "events"), databaseType: .clickhouse, host: "localhost")

        _ = await vm.deleteRow(RowLocator(row: ["1", nil], keyValues: nil))

        let first = try #require(plugin.countQueries.first)
        #expect(first.query == #"SELECT COUNT(*) FROM "events" WHERE "id" = ? AND "name" IS NULL"#)
        #expect(first.parameters == ["1"])
    }

    @Test("An edit is refused when another row holds the same value in every column")
    func identicalRowEditIsRefused() async {
        let plugin = StubPluginDriver()
        plugin.rowCounts = [2]
        let vm = RowDetailViewModel(
            columns: columns,
            rows: [Row(cells: [.text("1"), .text("signup")])],
            initialIndex: 0,
            table: TableInfo(name: "events"),
            session: session(plugin),
            columnDetails: columns
        )
        vm.startEditing()
        vm.setEditedValue("purchase", at: 1)

        let saved = await vm.saveChanges()

        #expect(!saved)
        #expect(vm.operationError?.title == String(localized: "Identical Rows"))
        #expect(plugin.parameterizedQueries.isEmpty)
    }

    @Test("A delete is refused when another row holds the same value in every column")
    func identicalRowDeleteIsRefused() async {
        let plugin = StubPluginDriver()
        plugin.rowCounts = [2]
        let vm = DataBrowserViewModel()
        vm.attach(session: session(plugin), table: TableInfo(name: "events"), databaseType: .clickhouse, host: "localhost")

        let deleted = await vm.deleteRow(RowLocator(row: ["1", "signup"], keyValues: nil))

        #expect(!deleted)
        #expect(vm.operationError?.title == String(localized: "Identical Rows"))
        #expect(plugin.generatedChanges.isEmpty)
    }

    @Test("A delete whose row is still there afterwards says so")
    func deleteThatLeftItsRowFails() async {
        let plugin = StubPluginDriver()
        plugin.rowCounts = [1, 1]
        let vm = DataBrowserViewModel()
        vm.attach(session: session(plugin), table: TableInfo(name: "events"), databaseType: .clickhouse, host: "localhost")

        let deleted = await vm.deleteRow(RowLocator(row: ["1", "signup"], keyValues: nil))

        #expect(!deleted)
        #expect(vm.operationError?.title == String(localized: "Row Not Deleted"))
    }

    @Test("An insert on an engine that writes its own rows goes to its writer, leaving out what the row leaves out")
    func insertGoesToTheWriter() throws {
        let plugin = StubPluginDriver()
        let driver = PluginBackedDriver(plugin: plugin, dialedHosts: [], rowIdentity: .everyColumn, readsOnly: { _ in true })

        let batch = try #require(try RowInsertPlanner.batch(
            table: "events",
            schema: nil,
            type: .clickhouse,
            driver: driver,
            columns: columns,
            rows: [PayloadRow(values: ["name": .text("x")])]
        ))

        guard case .driver(let writes, _) = batch else {
            Issue.record("expected the driver's own writes")
            return
        }
        #expect(writes.map(\.statement) == ["WRITE insert events"])
        #expect(plugin.generatedInserts[0] == [.text(PluginBackedDriver.defaultSentinel), "x"])
    }
}
