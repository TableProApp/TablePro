import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct MobileExportDataSourceTests {
    private func table(_ name: String, schema: String? = "public", scope: PluginExportRowScope = .unrestricted) -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: "", tableType: "table", schema: schema, kind: .table, rowScope: scope
        )
    }

    private func collect(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws
        -> (header: PluginStreamHeader?, rows: [PluginRow]) {
        var header: PluginStreamHeader?
        var rows: [PluginRow] = []
        for try await element in stream {
            switch element {
            case .header(let value): header = value
            case .rows(let batch): rows += batch
            }
        }
        return (header, rows)
    }

    @Test("Rows reach the format as the driver read them: bytes, NULL and the column types kept")
    func bytesNullAndTypesPassThrough() async throws {
        let driver = RecordingTransferDriver()
        let blob = Data([0x00, 0xFF, 0x10])
        driver.scriptedRows["SELECT * FROM \"public\".\"files\""] = (
            PluginStreamHeader(columns: ["id", "body", "note"], columnTypeNames: ["int4", "bytea", "text"]),
            [[.text("1"), .bytes(blob), .null]]
        )
        let source = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: driver, databaseType: .postgresql, readOnly: false
        )

        let read = try await collect(source.streamRows(for: table("files")))

        #expect(read.header?.columnTypeNames == ["int4", "bytea", "text"])
        #expect(read.rows == [[.text("1"), .bytes(blob), .null]])
    }

    @Test("Read-Only reads every row through the driver's read-only mode")
    func readOnlyReachesTheDriver() async throws {
        let driver = RecordingTransferDriver()
        let source = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: driver, databaseType: .postgresql, readOnly: true
        )
        _ = try await collect(source.streamRows(for: table("t")))
        #expect(driver.exportReadOnlyFlags == [true])
    }

    @Test("A row scope narrows the columns and rows the way the macOS adapter does")
    func rowScopeNarrowsTheSelect() throws {
        let source = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: RecordingTransferDriver(), databaseType: .postgresql, readOnly: false
        )
        let scoped = table("t", scope: PluginExportRowScope(filter: "id > 3;", rowLimit: 10, columns: ["id", "name"]))

        #expect(try source.rowsQuery(for: scoped)
            == "SELECT \"id\", \"name\" FROM \"public\".\"t\" WHERE id > 3 LIMIT 10 OFFSET 0")
        #expect(source.rowCountQuery(for: scoped) == nil)
        #expect(source.rowCountQuery(for: table("t")) == "SELECT COUNT(*) FROM \"public\".\"t\"")
    }

    @Test("The engine's own rows statement wins when the scope is the whole object")
    func catalogRowsQueryWins() throws {
        let catalog = StubExportCatalog()
        catalog.customRowsQuery = "SELECT * FROM ONLY \"public\".\"t\""
        let source = MobileExportDataSource(
            catalog: catalog, driver: RecordingTransferDriver(), databaseType: .postgresql, readOnly: false
        )
        #expect(try source.rowsQuery(for: table("t")) == "SELECT * FROM ONLY \"public\".\"t\"")
        #expect(source.rowCountQuery(for: table("t")) == nil)
    }

    @Test("An engine with no schema layer qualifies by the database the catalog named")
    func databaseQualifiesWithoutSchema() {
        let source = MobileExportDataSource(
            catalog: StubExportCatalog(databaseTypeId: "MySQL"), driver: RecordingTransferDriver(),
            databaseType: .mysql, readOnly: false
        )
        let object = PluginExportTable(name: "t", databaseName: "shop", tableType: "table", schema: nil, kind: .table)
        #expect(source.qualifiedName(of: object) == "\"shop\".\"t\"")
    }

    // On the session holding the user's transaction, the dump's COMMIT would end the user's work.
    @Test("Snapshot statements are dropped on the user's session and at Read-Only, and sent otherwise")
    func snapshotStatementsSkipWhereTheyCannotRun() async throws {
        let onSession = RecordingTransferDriver()
        let sessionSource = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: onSession, databaseType: .sqlite, readOnly: false,
            skipsSnapshotStatements: true
        )
        _ = try await sessionSource.execute(query: "BEGIN")
        _ = try await sessionSource.execute(query: "  COMMIT")
        #expect(onSession.executed.isEmpty)

        let readOnly = RecordingTransferDriver()
        let readOnlySource = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: readOnly, databaseType: .postgresql, readOnly: true
        )
        _ = try await readOnlySource.execute(query: "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        #expect(readOnly.executed.isEmpty)

        let dedicated = RecordingTransferDriver()
        let dedicatedSource = MobileExportDataSource(
            catalog: StubExportCatalog(), driver: dedicated, databaseType: .postgresql, readOnly: false
        )
        _ = try await dedicatedSource.execute(query: "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        #expect(dedicated.executed == ["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"])
    }

    @Test("A routine whose kind is unknown gets no drop, since PostgreSQL refuses the wrong one")
    func routineWithoutKindWritesNoDrop() {
        let catalog = StubExportCatalog()
        catalog.dropStatements = ["f": "DROP FUNCTION IF EXISTS f"]
        let source = MobileExportDataSource(
            catalog: catalog, driver: RecordingTransferDriver(), databaseType: .postgresql, readOnly: false
        )
        let known = PluginExportTable(name: "f", databaseName: "", tableType: "function", schema: nil, kind: .routine)
        let unknown = PluginExportTable(name: "f", databaseName: "", tableType: "routine", schema: nil, kind: .routine)
        #expect(source.dropStatement(for: known) == "DROP FUNCTION IF EXISTS f")
        #expect(source.dropStatement(for: unknown) == nil)
    }

    @Test("Selected rows refuse a cut or binary cell and keep every other value")
    func rowSetRefusesIncompleteCells() throws {
        let columns = [
            ColumnInfo(name: "id", typeName: "int", ordinalPosition: 0),
            ColumnInfo(name: "photo", typeName: "blob", ordinalPosition: 1)
        ]
        #expect(throws: ClipboardExporter.IncompleteValues(columns: ["photo"])) {
            try ExportRowSet(columns: columns, cells: [[.text("1"), .binary(byteCount: 4, ref: nil)]])
        }
        let rows = try ExportRowSet(columns: columns, cells: [[.text("1"), .null]])
        #expect(rows.rows == [[.text("1"), .null]])
        #expect(rows.columnTypeNames == ["int", "blob"])
    }

    @Test("Held rows take the SQL format's snapshot statements as no-ops and refuse any other statement")
    func rowsSourcePassesSnapshotStatements() async throws {
        let source = MobileRowsExportDataSource(
            rows: ExportRowSet(columns: ["n"], columnTypeNames: ["int"], rows: [[.text("1")]]),
            databaseType: .postgresql, sessionDriver: nil
        )
        for dialect in [SqlDialect.mysql, .postgres, .sqlite] {
            let snapshot = SQLExportSnapshot(dialect: dialect)
            try await snapshot.begin(on: source)
            await snapshot.end(on: source)
        }
        _ = try await source.execute(query: "COMMIT")
        _ = try await source.execute(query: "ROLLBACK")
        await #expect(throws: PluginExportError.self) {
            _ = try await source.execute(query: "SELECT 1")
        }
    }

    @Test("Held rows stream a slice at a time after the header")
    func rowsSourceStreamsInSlices() async throws {
        let values = (0..<1_200).map { [PluginCellValue.text("\($0)")] }
        let source = MobileRowsExportDataSource(
            rows: ExportRowSet(columns: ["n"], columnTypeNames: ["int"], rows: values),
            databaseType: .postgresql, sessionDriver: nil
        )
        var batches: [Int] = []
        for try await element in source.streamRows(table: "q", databaseName: "") {
            if case .rows(let rows) = element { batches.append(rows.count) }
        }
        #expect(batches == [500, 500, 200])
        #expect(try await source.fetchApproximateRowCount(table: "q", databaseName: "") == 1_200)
    }
}
