import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProTestSupport
import Testing

private struct SchemaRefused: LocalizedError {
    var errorDescription: String? { "schema \"sales\" does not exist" }
}

struct ExportRunTests {
    private func request(_ source: ExportSource, name: String = "orders", schema: String? = "public") -> ExportRequest {
        ExportRequest(
            formatId: "csv", source: source, fileName: name, connectionId: UUID(), databaseType: .postgresql,
            database: "shop", schema: schema, safeModeLevel: .off
        )
    }

    private let rows = ExportRowSet(
        columns: ["id", "name"], columnTypeNames: ["int4", "text"], rows: [[.text("1"), .text("Ada")], [.text("2"), .null]]
    )

    @Test("Held rows export to one file named after the export, in a folder of its own")
    func rowsExportWritesTheFile() async throws {
        let root = try TransferTestFolders.make("export-rows")
        let run = ExportRun(
            request: request(.rows(rows), name: "a/b"), plugin: MobileExportFormats.csv,
            drivers: UnreachableDriverProvider(), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(outcome.files.map(\.lastPathComponent) == ["a_b.csv"])
        #expect(outcome.folder.deletingLastPathComponent().resolvingSymlinksInPath().path
            == root.resolvingSymlinksInPath().path)
        #expect(outcome.rowsWritten == 2)
        let text = try String(contentsOf: try #require(outcome.files.first), encoding: .utf8)
        #expect(text.contains("Ada"))
        outcome.discard()
        #expect(!FileManager.default.fileExists(atPath: outcome.folder.path))
        TransferFiles.remove(root)
    }

    @Test("A stop before the run starts throws and writes nothing")
    func stopBeforeStartLeavesNothing() async throws {
        let root = try TransferTestFolders.make("export-early-stop")
        let run = ExportRun(
            request: request(.rows(rows)), plugin: MobileExportFormats.csv,
            drivers: UnreachableDriverProvider(), exportsRoot: root
        )
        run.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await run.run { _ in }
        }
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @Test("A stop while the plugin writes removes its partial file and the folder")
    func stopMidRunLeavesNoFile() async throws {
        let root = try TransferTestFolders.make("export-stop")
        let plugin = GatedExportPlugin()
        let run = ExportRun(
            request: request(.rows(rows)), plugin: plugin, drivers: UnreachableDriverProvider(), exportsRoot: root
        )

        let running = Task { try await run.run { _ in } }
        await plugin.gate.waitUntilEntered()
        #expect(TransferTestFolders.contents(of: root).count == 1)
        run.cancel()
        await plugin.gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await running.value
        }
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @Test("A query export reads on the leased connection, asks for data only, and closes the lease")
    func queryExportIsDataOnly() async throws {
        let root = try TransferTestFolders.make("export-query")
        let driver = RecordingTransferDriver()
        driver.scriptedRows["SELECT * FROM orders WHERE total > 10"] = (
            PluginStreamHeader(columns: ["id"], columnTypeNames: ["int4"]), [[.text("7")]]
        )
        let run = ExportRun(
            request: request(.query("SELECT * FROM orders WHERE total > 10")), plugin: MobileExportFormats.sql,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        let text = try String(contentsOf: try #require(outcome.files.first), encoding: .utf8)
        #expect(!text.contains("CREATE TABLE"))
        #expect(!text.contains("DROP TABLE"))
        #expect(text.contains("INSERT INTO"))
        #expect(driver.isDisconnected)
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("The session's own connection is never closed by the export")
    func sessionLeaseStaysOpen() async throws {
        let root = try TransferTestFolders.make("export-session")
        let driver = RecordingTransferDriver()
        let run = ExportRun(
            request: request(.query("SELECT 1")), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver, isSessionDriver: true), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(!driver.isDisconnected)
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("The formats offered follow each plugin's engine list, in the macOS order")
    func formatsPerEngine() {
        let ids = { (type: DatabaseType) in MobileExportFormats.available(for: type).map { Swift.type(of: $0).formatId } }
        #expect(ids(.postgresql) == ["csv", "json", "sql", "xlsx", "md"])
        #expect(ids(.mongodb) == ["csv", "json", "xlsx", "md", "mql"])
        #expect(ids(.redis) == ["csv", "json", "xlsx", "md"])
    }

    @Test("Export Results runs a read again, and only where the engine holds it to read-only")
    func resultsRerunOnlyReads() {
        func rerun(_ sent: [String], _ type: DatabaseType, readOnly: Bool = true) -> String? {
            QueryEditorViewModel.rerunnableStatement(sent, databaseType: type, runsReadOnly: readOnly)
        }
        #expect(rerun(["SELECT * FROM t"], .postgresql) == "SELECT * FROM t")
        #expect(rerun(["SELECT public.post_payment(42)"], .postgresql, readOnly: false) == nil)
        #expect(rerun(["DELETE FROM t RETURNING *"], .postgresql) == nil)
        #expect(rerun(["CALL refresh()"], .mysql) == nil)
        #expect(rerun(["CREATE TEMP TABLE x AS SELECT 1", "SELECT * FROM x"], .postgresql) == nil)
        #expect(rerun([], .postgresql) == nil)
    }

    @Test("A result runs again in the engine's read-only mode even with Safe Mode off")
    func rerunReadsReadOnly() async throws {
        let root = try TransferTestFolders.make("export-rerun")
        let driver = RecordingTransferDriver()
        driver.enforcesReadOnlyMode = true
        let run = ExportRun(
            request: request(.rerun("SELECT public.post_payment(42)")), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(driver.executed == ["SELECT public.post_payment(42)"])
        #expect(driver.exportReadOnlyFlags == [true])
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("A result is not run again on a connection that cannot hold it to read-only")
    func rerunRefusedWithoutReadOnlyMode() async throws {
        let root = try TransferTestFolders.make("export-rerun-refused")
        let driver = RecordingTransferDriver()
        let run = ExportRun(
            request: request(.rerun("SELECT public.post_payment(42)")), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        await #expect(throws: MobileTransferRefusal.self) {
            _ = try await run.run { _ in }
        }
        #expect(driver.executed.isEmpty)
        #expect(driver.isDisconnected)
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @Test("A connection of the export's own is set to the window's schema before it reads")
    func dedicatedConnectionReadsTheChosenSchema() async throws {
        let root = try TransferTestFolders.make("export-schema")
        let driver = RecordingTransferDriver()
        driver.supportsSchemas = true
        let run = ExportRun(
            request: request(.query("SELECT * FROM orders"), schema: "sales"), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(driver.executed == ["switchSchema(sales)", "SELECT * FROM orders"])
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("A connection that opened on the window's schema is left on the server's own search path")
    func connectionAlreadyOnTheSchemaIsLeftAlone() async throws {
        let root = try TransferTestFolders.make("export-schema-same")
        let driver = RecordingTransferDriver()
        driver.supportsSchemas = true
        driver.currentSchema = "sales"
        let run = ExportRun(
            request: request(.query("SELECT * FROM orders"), schema: "sales"), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(driver.executed == ["SELECT * FROM orders"])
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("A schema the connection cannot switch to fails the export before it reads, and leaves no file")
    func schemaSwitchFailureReadsNothing() async throws {
        let root = try TransferTestFolders.make("export-schema-refused")
        let driver = RecordingTransferDriver()
        driver.supportsSchemas = true
        driver.schemaSwitchFailure = SchemaRefused()
        let run = ExportRun(
            request: request(.query("SELECT * FROM orders"), schema: "sales"), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )

        do {
            _ = try await run.run { _ in }
            Issue.record("The export read without its schema")
        } catch let refusal as MobileTransferRefusal {
            #expect(refusal.reason.contains("sales"))
        }
        #expect(driver.executed == ["switchSchema(sales)"])
        #expect(driver.isDisconnected)
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @Test("The window's own session keeps the schema it reads in")
    func sessionLeaseKeepsItsSchema() async throws {
        let root = try TransferTestFolders.make("export-session-schema")
        let driver = RecordingTransferDriver()
        driver.supportsSchemas = true
        let run = ExportRun(
            request: request(.query("SELECT 1"), schema: "sales"), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: driver, isSessionDriver: true), exportsRoot: root
        )

        let outcome = try await run.run { _ in }

        #expect(driver.executed == ["SELECT 1"])
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("The object list keeps every kind the database has, whatever format it was read for")
    func listingKeepsEveryKind() async throws {
        let driver = RecordingTransferDriver()
        let catalog = StubExportCatalog()
        catalog.objects = [
            PluginExportTable(name: "orders", databaseName: "shop", tableType: "table", schema: "public", kind: .table),
            PluginExportTable(name: "total", databaseName: "shop", tableType: "function", schema: "public", kind: .routine),
            PluginExportTable(name: "audit", databaseName: "shop", tableType: "trigger", schema: "public", kind: .trigger),
            PluginExportTable(name: "ids", databaseName: "shop", tableType: "sequence", schema: "public", kind: .sequence)
        ]
        driver.exportCatalog = catalog

        let objects = try await ExportObjectListing.load(
            drivers: FixedDriverProvider(driver: driver), databaseType: .postgresql, database: "shop", schema: "public",
            plugin: MobileExportFormats.csv
        )

        #expect(objects.map(\.name) == ["orders", "total", "audit", "ids"])
        #expect(driver.isDisconnected)
    }

    @Test("Selected rows are matched with the escaping of the connection that reads them, not the window's")
    func rowsSelectFollowsTheReadingConnection() async throws {
        let select = DataBrowserViewModel.rowsSelect(
            table: "t", schema: nil, database: "shop", type: .mysql, keys: [[(column: "k", value: #"a\b"#)]],
            columns: [ColumnInfo(name: "k", typeName: "varchar(10)", ordinalPosition: 0)]
        )
        let escaping = RecordingTransferDriver()
        escaping.literalEscaping = { $0.replacingOccurrences(of: "\\", with: "\\\\") }
        let literal = RecordingTransferDriver()

        #expect(select.statement(on: escaping).hasSuffix(#"= 'a\\b')"#))
        #expect(select.statement(on: literal).hasSuffix(#"= 'a\b')"#))

        let root = try TransferTestFolders.make("export-rows-escaping")
        let run = ExportRun(
            request: request(.query(select)), plugin: MobileExportFormats.csv,
            drivers: FixedDriverProvider(driver: escaping), exportsRoot: root
        )
        let outcome = try await run.run { _ in }

        #expect(escaping.executed == [select.statement(on: escaping)])
        outcome.discard()
        TransferFiles.remove(root)
    }

    @Test("Redis keys have no Export of their own: the export's objects are its databases")
    func redisKeysExportByDatabase() {
        let redis = RedisDriver(host: "localhost", port: 6_379, password: nil)
        #expect(ExportObjectListing.supportsExport(redis))
        #expect(!ExportObjectListing.supportsTableExport(redis))
        #expect(ExportObjectListing.supportsTableExport(RecordingTransferDriver()))
    }

    @Test("A stop ends the run at once, stops the driver's statement and closes the connection")
    func stopInterruptsTheRead() async throws {
        let root = try TransferTestFolders.make("export-stop-read")
        let driver = RecordingTransferDriver()
        driver.stall = .untilInterrupted
        let run = ExportRun(
            request: request(.query("SELECT 1")), plugin: ExecutingExportPlugin(),
            drivers: FixedDriverProvider(driver: driver), exportsRoot: root
        )
        let running = Task { try await run.run { _ in } }
        await driver.waitUntilStalled()

        run.cancel()

        let ended = try #require(await BoundedCall.result(within: .seconds(5)) { await running.result })
        #expect(throws: CancellationError.self) { try ended.get() }
        try await waitUntil { driver.isDisconnected }
        #expect(driver.interrupts == 1)
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @MainActor
    @Test("Background expiry ends the run within the grace, releases the hold, and closes a connection that never answers")
    func expiryReleasesAnUnresponsiveConnection() async throws {
        let root = try TransferTestFolders.make("export-expiry")
        let driver = RecordingTransferDriver()
        driver.stall = .unresponsive
        let asserter = RecordingAsserter()
        let hold = FakeHold()
        let background = TransferBackgroundRun(
            title: "Export", asserter: asserter, scheduler: nil, hold: { hold }, expiryGrace: .milliseconds(1)
        )
        let run = ExportRun(
            request: request(.query("SELECT 1")), plugin: ExecutingExportPlugin(),
            drivers: FixedDriverProvider(driver: driver), background: background, exportsRoot: root,
            stopGrace: .milliseconds(50)
        )
        let running = Task { try await run.run { _ in } }
        await driver.waitUntilStalled()

        asserter.fireExpiration()

        let ended = try #require(await BoundedCall.result(within: .seconds(5)) { await running.result })
        #expect(throws: CancellationError.self) { try ended.get() }
        #expect(hold.releases == 1)
        try await waitUntil { driver.isDisconnected }
        #expect(driver.interrupts == 1)
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        driver.endStall()
        TransferFiles.remove(root)
    }
}
