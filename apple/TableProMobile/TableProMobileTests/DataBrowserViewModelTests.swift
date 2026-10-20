import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProQuery
import Testing

@MainActor
@Suite("DataBrowserViewModel")
struct DataBrowserViewModelTests {
    private func makeSession(driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(
            connectionId: UUID(),
            driver: driver,
            activeDatabase: "test",
            tables: []
        )
    }

    private func makeColumns() -> [ColumnInfo] {
        [
            ColumnInfo(name: "id", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
    }

    @Test("load without session sets loadError")
    func loadWithoutSessionSetsError() async {
        let vm = DataBrowserViewModel()
        vm.attach(session: nil, table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.loadError != nil)
        #expect(vm.isLoading == false)
    }

    @Test("load with session populates columns and rows")
    func loadPopulates() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(
                columns: makeColumns(),
                rows: [["1", "Alice"], ["2", "Bob"]],
                rowsAffected: 0,
                executionTime: 0.01
            )),
            .success(QueryResult(columns: [], rows: [["2"]], rowsAffected: 0, executionTime: 0))
        ]

        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        #expect(vm.legacyRows.count == 2)
        #expect(vm.columnDetails.count == 2)
        #expect(vm.hasPrimaryKeys == true)
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("hasActiveSearch reflects activeSearchText")
    func searchFlagsTrack() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        #expect(vm.hasActiveSearch == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.applySearch("alice")
        #expect(vm.hasActiveSearch == true)
        #expect(vm.activeSearchText == "alice")

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.clearSearch()
        #expect(vm.hasActiveSearch == false)
        #expect(vm.activeSearchText == "")
    }

    @Test("clearSearch with existing rows replaces them without leaving loading flags stuck")
    func clearSearchReplacesRowsCleanly() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)
        #expect(vm.legacyRows.count == 1)
        #expect(vm.isLoading == false)
        #expect(vm.isPageLoading == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"], ["2", "Bob"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["2"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.clearSearch()

        #expect(vm.isLoading == false)
        #expect(vm.isPageLoading == false)
        #expect(vm.legacyRows.count == 2)
    }

    @Test("pagination prev/next clamps at boundaries")
    func paginationClamps() async {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        #expect(vm.pagination.currentPage == 0)
        await vm.goToPreviousPage()
        #expect(vm.pagination.currentPage == 0, "previous on page 0 should not underflow")
    }

    @Test("The page range reads in the app's language")
    func pageRangeLabelIsLocalized() throws {
        #expect(DataBrowserViewModel.pageRangeLabel(start: 1, end: 100, total: 3_503) == "1-100 of 3503")

        let path = try #require(Bundle.main.path(forResource: "vi", ofType: "lproj"))
        let vietnamese = try #require(Bundle(path: path))
        let label = DataBrowserViewModel.pageRangeLabel(start: 1, end: 100, total: 3_503, bundle: vietnamese)
        #expect(label == "1-100 trên 3503")
    }

    @Test("primaryKeyValues returns only PK columns from row")
    func primaryKeyExtraction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["42", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        let pks = vm.primaryKeyValues(forRowAt: 0)
        #expect(pks?.count == 1)
        #expect(pks?.first?.column == "id")
        #expect(pks?.first?.value == "42")
        #expect(vm.primaryKeyValues(forRowAt: 1) == nil)
    }

    @Test("A row whose key holds binary data gives no key values to delete it by")
    func binaryKeyGivesNoDeleteValues() async {
        let columns = [
            ColumnInfo(name: "id", typeName: "BINARY(16)", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 1)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: columns, rows: [["\u{1}\u{2}\u{3}", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "customers"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        #expect(vm.legacyRows.count == 1)
        #expect(vm.primaryKeyValues(forRowAt: 0) == nil)
    }

    @Test("Columns and foreign keys are read in the browser's schema, not the driver's")
    func metadataReadsBrowserSchema() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(
            session: makeSession(driver: driver), table: TableInfo(name: "customers"),
            databaseType: .postgresql, host: "localhost", schema: "crm"
        )
        await vm.load(isInitial: true)

        #expect(driver.fetchColumnsSchemas == ["crm"])
        #expect(driver.fetchForeignKeysSchemas == ["crm"])
        #expect(driver.executedQueries.first?.hasPrefix(#"SELECT * FROM "crm"."customers""#) == true)
    }

    @Test("A full value is read from the browser's schema")
    func fullValueReadsBrowserSchema() async throws {
        let driver = MockDatabaseDriver()
        driver.scriptedExecuteResults = [
            .success(QueryResult(
                columns: [ColumnInfo(name: "body", typeName: "TEXT", ordinalPosition: 0)],
                rows: [["the whole body"]],
                rowsAffected: 0,
                executionTime: 0
            ))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(
            session: makeSession(driver: driver), table: TableInfo(name: "notes"),
            databaseType: .postgresql, host: "localhost", schema: "crm"
        )
        let ref = CellRef(table: "notes", column: "body", primaryKey: [.init(column: "id", value: "7")])

        let value = try await vm.loadFullValue(driver: driver, ref: ref, databaseType: .postgresql, schema: vm.schema)

        #expect(value == "the whole body")
        #expect(driver.executedQueries == [#"SELECT "body" FROM "crm"."notes" WHERE "id" = '7' LIMIT 1"#])
    }

    @Test("A full value behind a key column with no type is read whichever way SQLite stored the key")
    func fullValueThroughUntypedKey() async throws {
        let columns = [
            ColumnInfo(name: "id", typeName: "", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "body", typeName: "TEXT", ordinalPosition: 1)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: columns, rows: [["5", "short"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "notes"), databaseType: .sqlite, host: "")
        await vm.load(isInitial: true)
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [columns[1]], rows: [["the whole body"]], rowsAffected: 0, executionTime: 0))
        ]
        let ref = CellRef(table: "notes", column: "body", primaryKey: [.init(column: "id", value: "5")])

        let value = try await vm.loadFullValue(driver: driver, ref: ref, databaseType: .sqlite, schema: nil)

        #expect(value == "the whole body")
        #expect(driver.executedQueries.last == #"SELECT "body" FROM "notes" WHERE "id" IN (5, '5') LIMIT 1"#)
    }

    @Test("A seeded filter is already in the first SELECT, and only the first seed counts")
    func seededFilterShapesFirstSelect() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["42", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        vm.seedFilters([TableFilter(columnName: "id", value: "42")])
        await vm.load(isInitial: true)
        vm.seedFilters([TableFilter(columnName: "name", value: "Bob")])

        #expect(driver.executedQueries.first?.contains("WHERE `id` = 42") == true)
        #expect(vm.activeFilterCount == 1)
        let seededColumns = vm.filters.map { $0.columnName }
        #expect(seededColumns == ["id"])
    }

    @Test("A seeded key spelled in another case than its TEXT column still compares as text")
    func seededFilterAcrossCaseStaysQuoted() async {
        let columns = [
            ColumnInfo(name: "code", typeName: "TEXT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "city", typeName: "TEXT", ordinalPosition: 1)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: columns, rows: [["02134", "Boston"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "zips"), databaseType: .sqlite, host: "")

        vm.seedFilters([TableFilter(columnName: "CODE", value: "02134")])
        await vm.load(isInitial: true)

        let select = driver.executedQueries.first ?? ""
        #expect(select.contains("'02134'"))
        #expect(!select.contains("= 02134"))
    }

    @Test("A seeded browser whose first load finds one row hands that match over once")
    func singleRowMatchIsTakenOnce() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["42", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        vm.seedFilters([TableFilter(columnName: "id", value: "42")])
        #expect(vm.takeSingleRowMatch() == false)

        await vm.load(isInitial: true)
        #expect(vm.takeSingleRowMatch())
        #expect(vm.takeSingleRowMatch() == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["42", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.load()
        #expect(vm.takeSingleRowMatch() == false)
    }

    @Test("No match is handed over for several rows, or for a browser nothing was seeded into")
    func singleRowMatchNeedsOneSeededRow() async {
        let several = MockDatabaseDriver()
        several.scriptedColumns = makeColumns()
        several.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["5", "Alice"], ["5", "Bob"]], rowsAffected: 0, executionTime: 0))
        ]
        let seeded = DataBrowserViewModel()
        seeded.attach(session: makeSession(driver: several), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        seeded.seedFilters([TableFilter(columnName: "id", value: "5")])
        await seeded.load(isInitial: true)
        #expect(seeded.takeSingleRowMatch() == false)

        let single = MockDatabaseDriver()
        single.scriptedColumns = makeColumns()
        single.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let unseeded = DataBrowserViewModel()
        unseeded.attach(session: makeSession(driver: single), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await unseeded.load(isInitial: true)
        #expect(unseeded.takeSingleRowMatch() == false)
    }

    // The preview's lookup uses the same rule, so Open Table lists the row the preview showed.
    @Test("A seeded key and a user filter on a column without a type match the number either way it was stored",
          arguments: ["", "BLOB", "ANY"])
    func untypedKeyColumnMatchesEitherStorageClass(typeName: String) async {
        let columns = [
            ColumnInfo(name: "code", typeName: typeName, ordinalPosition: 0),
            ColumnInfo(name: "label", typeName: "TEXT", ordinalPosition: 1)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: columns, rows: [["5", "integer five"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "parents"), databaseType: .sqlite, host: "")
        vm.seedFilters([TableFilter(columnName: "CODE", value: "5")])
        await vm.load(isInitial: true)

        #expect((driver.executedQueries.first ?? "").contains("\"CODE\" IN (5, '5')"))
        #expect(vm.takeSingleRowMatch())

        let userDriver = MockDatabaseDriver()
        userDriver.scriptedColumns = columns
        let unseeded = DataBrowserViewModel()
        unseeded.attach(session: makeSession(driver: userDriver), table: TableInfo(name: "parents"), databaseType: .sqlite, host: "")
        unseeded.filters = [TableFilter(columnName: "code", value: "5")]
        await unseeded.load(isInitial: true)
        #expect((userDriver.executedQueries.first ?? "").contains("\"code\" IN (5, '5')"))
    }

    @Test("A load overtaken during its row count leaves the newer load's total and loading state alone")
    func overtakenCountIsDropped() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let gate = ExecuteGate(holding: [2, 3])
        driver.beforeExecute = { await gate.pass() }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"], ["2", "Bob"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["50"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")

        let overtaken = Task { await vm.changePageSize(2) }
        await gate.arrival(of: 2)

        vm.filters = [TableFilter(columnName: "name", value: "Alice")]
        let filtered = Task { await vm.applyFilters() }
        await gate.arrival(of: 3)

        await gate.release(2)
        await overtaken.value
        #expect(vm.pagination.totalRows == nil)
        #expect(vm.isPageLoading)

        await gate.release(3)
        await filtered.value
        #expect(vm.pagination.totalRows == 1)
        #expect(vm.legacyRows.count == 1)
        #expect(vm.isLoading == false)
        #expect(vm.isPageLoading == false)
    }

    @Test("deleteRow returns true on success and runs DELETE SQL")
    func deleteSuccess() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(vm.operationError == nil)
        #expect(driver.executedQueries.contains(where: { $0.uppercased().hasPrefix("DELETE") }))
    }

    @Test("A binary, NULL or ref-less cut key cell gives no key, and a cut one with a ref gives the whole key")
    func nonTextKeyGivesNoKey() async {
        let columns = [
            ColumnInfo(name: "tenant", typeName: "INT", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
            ColumnInfo(name: "id", typeName: "BINARY", isPrimaryKey: true, isNullable: false, ordinalPosition: 1),
            ColumnInfo(name: "name", typeName: "VARCHAR(64)", ordinalPosition: 2)
        ]
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = columns
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: columns, rows: [["1", "x", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        let keyValues = { (cells: [Cell]) in
            RowDetailViewModel.primaryKeyValues(cells: cells, columns: vm.columns, columnDetails: vm.columnDetails)
        }
        #expect(keyValues([.text("1"), .binary(byteCount: 16, ref: nil), .text("Alice")]) == nil)
        #expect(keyValues([.text("1"), .null, .text("Alice")]) == nil)
        #expect(keyValues([.text("1"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: nil), .text("Alice")]) == nil)
        let wholeKey = CellRef(table: "users", column: "id", primaryKey: [
            PrimaryKeyComponent(column: "tenant", value: "1"), PrimaryKeyComponent(column: "id", value: "long-key")
        ])
        let cutKey = keyValues([.text("1"), .truncatedText(prefix: "lo", totalBytes: 5_000, ref: wholeKey), .text("Alice")])
        #expect(cutKey?.map { $0.value } == ["1", "long-key"])

        let keys = keyValues([.text("1"), .text("7"), .text("Alice")])
        #expect(keys?.map { $0.column } == ["tenant", "id"])
        #expect(keys?.map { $0.value } == ["1", "7"])
    }

    @Test("A delete that leaves the row in the table reports it instead of succeeding")
    func deleteThatKeepsTheRowFails() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == false)
        #expect(vm.operationError?.title == String(localized: "Row Not Deleted"))
        #expect(driver.executedQueries.contains { $0.hasPrefix("SELECT `id` FROM `users` WHERE `id` = 1") })
        #expect(vm.legacyRows == [["1", "Alice"]])
    }

    @Test("A delete whose count reads 0, as under SET NOCOUNT ON, succeeds once the row is gone")
    func uncountedDeleteOfAGoneRowSucceeds() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(vm.operationError == nil)
    }

    @Test("deleteRow returns false and sets operationError on driver failure")
    func deleteFailure() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == false)
        #expect(vm.operationError != nil)
    }

    @Test("deleteRow on an idle session opens a read-write transaction and commits it")
    func deleteWrapsIdleSession() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(driver.beganTransactionModes == [.readWrite])
        #expect(driver.didCommitTransaction)
    }

    @Test("a failed delete rolls the transaction back")
    func deleteFailureRollsBack() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .idle
        driver.scriptedExecuteResults = [.failure(MockDatabaseDriver.MockError.scripted)]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == false)
        #expect(driver.didRollbackTransaction)
        #expect(!driver.didCommitTransaction)
    }

    @Test("deleteRow joins a transaction the session already holds")
    func deleteJoinsOpenTransaction() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["1"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        driver.scriptedTransactionState = .explicitTransaction
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]

        let success = await vm.deleteRow(pkValues: [(column: "id", value: "1")])
        #expect(success == true)
        #expect(!driver.didBeginTransaction)
        #expect(!driver.didCommitTransaction)
    }

    private func bodyRef(_ column: String) -> CellRef {
        CellRef(table: "users", column: column, primaryKey: [PrimaryKeyComponent(column: "id", value: "1")])
    }

    @Test("Loading a full value from a row that is gone throws, so it never reads as NULL")
    func loadFullValueOfMissingRowThrows() async throws {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [[nil]], rowsAffected: 0, executionTime: 0))
        ]

        await #expect(throws: CellLookupError.rowNotFound) {
            try await vm.loadFullValue(driver: driver, ref: bodyRef("bio"), databaseType: .mysql, schema: nil)
        }
        let storedNull = try await vm.loadFullValue(driver: driver, ref: bodyRef("bio"), databaseType: .mysql, schema: nil)
        #expect(storedNull == nil)
    }

    @Test("A full value is read from the schema's table, the one Save and Delete write to")
    func loadFullValueReadsTheBrowsedSchema() async throws {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        driver.scriptedExecuteResults = [.success(QueryResult(columns: [], rows: [["full"]], rowsAffected: 0, executionTime: 0))]

        #expect(try await vm.loadFullValue(driver: driver, ref: bodyRef("bio"), databaseType: .postgresql, schema: "sales") == "full")
        #expect(driver.executedQueries.first?.contains(#"FROM "sales"."users" WHERE"#) == true)
    }

    @Test("Completing rows keeps reading the schema they came from after the browser switches schema")
    func completeRowsKeepsTheirSchema() async throws {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .postgresql, host: "localhost", schema: "sales")
        driver.beforeExecute = { @MainActor in
            vm.attach(session: nil, table: TableInfo(name: "users"), databaseType: .postgresql, host: "localhost", schema: "archive")
        }
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [["a"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["b"]], rowsAffected: 0, executionTime: 0))
        ]
        let rows: [[Cell]] = [
            [.text("1"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: bodyRef("bio"))],
            [.text("1"), .truncatedText(prefix: "b", totalBytes: 5_000, ref: bodyRef("notes"))]
        ]

        _ = try await vm.completeRows(rows, driver: driver)

        #expect(vm.schema == "archive")
        #expect(driver.executedQueries.count == 2)
        #expect(driver.executedQueries.allSatisfy { $0.contains(#"FROM "sales"."users" WHERE"#) })
    }

    @Test("A page export reads full values only while the device has room for them, the text and its copy")
    func exportFitsInFreeMemory() {
        let margin = 64 * 1_024 * 1_024
        #expect(DataBrowserViewModel.exportFits(pendingBytes: 0, availableBytes: 1))
        #expect(DataBrowserViewModel.exportFits(pendingBytes: 10_000_000, availableBytes: 0))
        #expect(DataBrowserViewModel.exportFits(pendingBytes: 10_000_000, availableBytes: margin + 40_000_001))
        #expect(!DataBrowserViewModel.exportFits(pendingBytes: 10_000_000, availableBytes: margin + 40_000_000))
        #expect(!DataBrowserViewModel.exportFits(pendingBytes: 200_000_000, availableBytes: 500_000_000))
        #expect(!DataBrowserViewModel.exportFits(pendingBytes: .max, availableBytes: .max))
    }

    @Test("Completing a row reads each cut value that has a ref, one query per value")
    func completeRowsReadsCutValues() async throws {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        let full = String(repeating: "a", count: 5_000)
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: [], rows: [[full]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [[nil]], rowsAffected: 0, executionTime: 0))
        ]
        let cells: [Cell] = [
            .text("1"),
            .truncatedText(prefix: "aaa", totalBytes: 5_000, ref: bodyRef("bio")),
            .truncatedText(prefix: "bbb", totalBytes: 5_000, ref: bodyRef("notes")),
            .null
        ]
        #expect(DataBrowserViewModel.canComplete(cells))

        let complete = try await vm.completeRows([cells], driver: driver)[0]

        #expect(driver.executedQueries.count == 2)
        #expect(driver.executedQueries.first?.contains("`bio`") == true)
        #expect(Row(cells: complete).legacyValues == ["1", full, nil, nil])
    }

    @Test("A binary value or a cut value with no ref cannot be completed, so the export names its column")
    func uncompletableCellsBlockExport() async throws {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        let columns = [
            ColumnInfo(name: "id", typeName: "INT", ordinalPosition: 0),
            ColumnInfo(name: "avatar", typeName: "BLOB", ordinalPosition: 1)
        ]
        let binary: [Cell] = [.text("1"), .binary(byteCount: 16, ref: bodyRef("avatar"))]
        let keyless: [Cell] = [.text("1"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: nil)]
        #expect(!DataBrowserViewModel.canComplete(binary))
        #expect(!DataBrowserViewModel.canComplete(keyless))

        let complete = try await vm.completeRows([binary], driver: driver)[0]

        #expect(driver.executedQueries.isEmpty)
        #expect(throws: ClipboardExporter.IncompleteValues(columns: ["avatar"])) {
            try ClipboardExporter.exportRow(columns: columns, cells: complete, format: .json, databaseType: .mysql, driver: nil)
        }
    }

    @Test("A row that is gone stops the completion instead of exporting NULL")
    func completeRowsOfMissingRowThrows() async {
        let driver = MockDatabaseDriver()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [.success(QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0))]
        let cells: [Cell] = [.text("1"), .truncatedText(prefix: "a", totalBytes: 5_000, ref: bodyRef("bio"))]

        await #expect(throws: CellLookupError.rowNotFound) {
            try await vm.completeRows([cells], driver: driver)
        }
    }

    @Test("changePageSize resets currentPage and totalRows")
    func changePageSizeResets() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["0"]], rowsAffected: 0, executionTime: 0))
        ]
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        await vm.load(isInitial: true)

        await vm.changePageSize(50)
        #expect(vm.pagination.pageSize == 50)
        #expect(vm.pagination.currentPage == 0)
    }

    private func emptyResult() -> Result<QueryResult, Error> {
        .success(QueryResult(columns: makeColumns(), rows: [], rowsAffected: 0, executionTime: 0))
    }

    @Test("The page bar stays hidden for an empty table and shows once rows load")
    func pageBarFollowsRows() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        #expect(vm.showsPaginationBar == false)

        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)
        #expect(vm.showsPaginationBar == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.load(isInitial: true)
        #expect(vm.showsPaginationBar)
    }

    @Test("The page bar stays up when a search finds nothing, so the search can be paged back out of")
    func pageBarSurvivesEmptySearch() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)

        driver.scriptedExecuteResults = [emptyResult()]
        await vm.applySearch("nobody")

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.showsPaginationBar)
    }

    @Test("The page bar stays up when an enabled filter matches nothing")
    func pageBarSurvivesEmptyFilter() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.load(isInitial: true)

        vm.filters = [TableFilter(columnName: "name", value: "nobody")]
        driver.scriptedExecuteResults = [emptyResult()]
        await vm.applyFilters()

        #expect(vm.legacyRows.isEmpty)
        #expect(vm.showsPaginationBar)
    }

    @Test("Page steps are offered only where a page exists")
    func pageStepsFollowPosition() async {
        let driver = MockDatabaseDriver()
        driver.scriptedColumns = makeColumns()
        let vm = DataBrowserViewModel()
        vm.attach(session: makeSession(driver: driver), table: TableInfo(name: "users"), databaseType: .mysql, host: "localhost")
        #expect(vm.canGoToPreviousPage == false)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["1", "Alice"], ["2", "Bob"]], rowsAffected: 0, executionTime: 0)),
            .success(QueryResult(columns: [], rows: [["3"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.changePageSize(2)
        #expect(vm.pagination.totalRows == 3)
        #expect(vm.canGoToPreviousPage == false)
        #expect(vm.canGoToNextPage)

        driver.scriptedExecuteResults = [
            .success(QueryResult(columns: makeColumns(), rows: [["3", "Carol"]], rowsAffected: 0, executionTime: 0))
        ]
        await vm.goToNextPage()
        #expect(vm.pagination.currentPage == 1)
        #expect(vm.canGoToPreviousPage)
        #expect(vm.canGoToNextPage == false)
    }

    private func keyPage(from start: Int, count: Int, total: Int) -> KeyContentsPage {
        let columns = [
            ColumnInfo(name: "index", typeName: "integer", ordinalPosition: 0),
            ColumnInfo(name: "element", typeName: "string", ordinalPosition: 1)
        ]
        let rows: [[String?]] = (start ..< start + count).map { [String($0), "e\($0)"] }
        return KeyContentsPage(
            result: QueryResult(columns: columns, rows: rows, rowsAffected: 0, executionTime: 0),
            totalCount: total
        )
    }

    @Test("a key browse sends no SQL and pages by offset")
    func keyBrowsePagesByOffset() async {
        let driver = MockKeyContentsDriver()
        let vm = DataBrowserViewModel()
        let pageSize = vm.pagination.pageSize
        driver.scriptedPages = [
            .success(keyPage(from: 0, count: pageSize, total: pageSize * 3)),
            .success(keyPage(from: pageSize, count: pageSize, total: pageSize * 3))
        ]
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "queue"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)
        await vm.goToNextPage()

        #expect(driver.pageRequests == [
            MockKeyContentsDriver.PageRequest(key: "queue", limit: pageSize, offset: 0),
            MockKeyContentsDriver.PageRequest(key: "queue", limit: pageSize, offset: pageSize)
        ])
        #expect(driver.executedQueries.isEmpty)
        #expect(driver.fetchColumnsCalls == 0)
        #expect(driver.fetchForeignKeysCalls == 0)
        #expect(vm.pagination.totalRows == pageSize * 3)
        #expect(vm.columnDetails.map(\.name) == ["index", "element"])
        #expect(vm.hasPrimaryKeys == false)
        #expect(vm.legacyRows.first == [String(pageSize), "e\(pageSize)"])
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("a key read overtaken by a newer one leaves the newer page on screen")
    func overtakenKeyReadIsDropped() async {
        let driver = MockKeyContentsDriver()
        let vm = DataBrowserViewModel()
        let pageSize = vm.pagination.pageSize
        driver.scriptedPages = [
            .success(keyPage(from: 0, count: pageSize, total: pageSize * 3)),
            .success(keyPage(from: pageSize, count: pageSize, total: pageSize * 3))
        ]
        driver.holdsFirstRequest = true
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "queue"), databaseType: .redis, host: "localhost")

        let overtaken = Task { await vm.load(isInitial: true) }
        while !driver.isHoldingRequest {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await vm.load()
        driver.releaseHeldRequest()
        await overtaken.value

        #expect(driver.pageRequests.count == 2)
        #expect(vm.legacyRows.first == [String(pageSize), "e\(pageSize)"])
        #expect(vm.loadError == nil)
        #expect(vm.isLoading == false)
    }

    @Test("a short key page with no count settles the total from what arrived")
    func shortKeyPageSettlesTotal() async {
        let driver = MockKeyContentsDriver()
        driver.scriptedPages = [
            .success(KeyContentsPage(
                result: QueryResult(
                    columns: [ColumnInfo(name: "member", typeName: "string", ordinalPosition: 0)],
                    rows: [["x"], ["y"]],
                    rowsAffected: 0,
                    executionTime: 0
                ),
                totalCount: nil
            ))
        ]
        let vm = DataBrowserViewModel()
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "tags"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.pagination.totalRows == 2)
        #expect(vm.canGoToNextPage == false)
    }

    @Test("a key that cannot be read shows the error instead of rows")
    func unreadableKeyShowsError() async {
        let driver = MockKeyContentsDriver()
        driver.scriptedPages = [.failure(RedisError.keyNotFound("gone"))]
        let vm = DataBrowserViewModel()
        let session = ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "db0", tables: [])
        vm.attach(session: session, table: TableInfo(name: "gone"), databaseType: .redis, host: "localhost")

        await vm.load(isInitial: true)

        #expect(vm.loadError?.title == String(localized: "Key Not Found"))
        #expect(vm.legacyRows.isEmpty)
        #expect(vm.isLoading == false)
        #expect(driver.executedQueries.isEmpty)
    }
}

private actor ExecuteGate {
    private let heldCalls: Set<Int>
    private var calls = 0
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivalWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(holding heldCalls: Set<Int>) {
        self.heldCalls = heldCalls
    }

    func pass() async {
        calls += 1
        let call = calls
        guard heldCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            held[call] = continuation
            arrivalWaiters.removeValue(forKey: call)?.resume()
        }
    }

    func arrival(of call: Int) async {
        guard held[call] == nil else { return }
        await withCheckedContinuation { arrivalWaiters[call] = $0 }
    }

    func release(_ call: Int) {
        held.removeValue(forKey: call)?.resume()
    }
}
