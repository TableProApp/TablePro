import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import Testing
@testable import TableProMobile

struct ExportRunTests {
    private func request(_ source: ExportSource, name: String = "orders") -> ExportRequest {
        ExportRequest(
            formatId: "csv", source: source, fileName: name, connectionId: UUID(), databaseType: .postgresql,
            database: "shop", schema: "public", safeModeLevel: .off
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
        #expect(driver.disconnected)
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

        #expect(!driver.disconnected)
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

    @Test("Export Results runs a read again and nothing that writes")
    func resultsRerunOnlyReads() {
        #expect(QueryEditorViewModel.rerunnableStatement(["SELECT * FROM t"], databaseType: .postgresql) == "SELECT * FROM t")
        #expect(QueryEditorViewModel.rerunnableStatement(
            ["DELETE FROM t RETURNING *"], databaseType: .postgresql
        ) == nil)
        #expect(QueryEditorViewModel.rerunnableStatement(["CALL refresh()"], databaseType: .mysql) == nil)
        #expect(QueryEditorViewModel.rerunnableStatement(
            ["CREATE TEMP TABLE x AS SELECT 1", "SELECT * FROM x"], databaseType: .postgresql
        ) == nil)
        #expect(QueryEditorViewModel.rerunnableStatement([], databaseType: .postgresql) == nil)
    }
}
