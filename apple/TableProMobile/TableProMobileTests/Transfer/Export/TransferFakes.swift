import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting
@testable import TableProMobile

// A driver that answers export reads from scripted rows and records every statement it is sent.
final class RecordingTransferDriver: DatabaseDriver, ExportRowStreaming, CatalogQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var readOnlyFlags: [Bool] = []
    var scriptedRows: [String: (header: PluginStreamHeader, rows: [PluginRow])] = [:]
    var transactionState: DriverTransactionState = .idle
    private(set) var disconnected = false

    var executed: [String] { lock.withLock { sent } }
    var exportReadOnlyFlags: [Bool] { lock.withLock { readOnlyFlags } }

    private func record(_ query: String) {
        lock.withLock { sent.append(query) }
    }

    func exportRows(query: String, readOnly: Bool) -> AsyncThrowingStream<PluginStreamElement, Error> {
        lock.withLock {
            sent.append(query)
            readOnlyFlags.append(readOnly)
        }
        let script = scriptedRows[query]
        return AsyncThrowingStream { continuation in
            if let script {
                continuation.yield(.header(script.header))
                if !script.rows.isEmpty { continuation.yield(.rows(script.rows)) }
            }
            continuation.finish()
        }
    }

    func catalogQuery(_ sql: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        record(sql)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func connect() async throws {}
    func disconnect() async throws { lock.withLock { disconnected = true } }
    func ping() async throws -> Bool { true }
    func execute(query: String) async throws -> QueryResult {
        record(query)
        return QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func cancelCurrentQuery() async throws {}
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    var supportsSchemas: Bool { false }
    func switchSchema(to name: String) async throws {}
    func fetchSchemas() async throws -> [String] { [] }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }
    func beginTransaction() async throws { record("BEGIN") }
    func commitTransaction() async throws { record("COMMIT") }
    func rollbackTransaction() async throws { record("ROLLBACK") }
    func sessionTransactionState() async -> DriverTransactionState { transactionState }
    var serverVersion: String? { nil }
}

// Every catalog answer at its default but the ones a test sets.
final class StubExportCatalog: MobileExportCatalog, @unchecked Sendable {
    let databaseTypeId: String
    var objects: [PluginExportTable] = []
    var customRowsQuery: String?
    var dropStatements: [String: String] = [:]

    init(databaseTypeId: String = "PostgreSQL") {
        self.databaseTypeId = databaseTypeId
    }

    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable] { objects }
    func rowsQuery(for object: PluginExportTable) -> String? { customRowsQuery }
    func quoteIdentifier(_ identifier: String) -> String { SQLQuoting.identifier(identifier) }
    func escapeStringLiteral(_ value: String) -> String { SQLEscaping.ansiStringLiteral(value) }
    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "CREATE TABLE \(table) ()" }
    func dropStatement(for object: PluginExportTable) -> String? { dropStatements[object.name] }
}

// A provider that hands out one driver and says whether it is the window's session.
struct FixedDriverProvider: TransferDriverProvider {
    let driver: any DatabaseDriver
    var isSessionDriver = false

    func openTransferDriver() async throws -> TransferDriverLease {
        let driver = driver
        let isSession = isSessionDriver
        return TransferDriverLease(driver: driver, isSessionDriver: isSession) {
            guard !isSession else { return }
            try? await driver.disconnect()
        }
    }
}

struct UnreachableDriverProvider: TransferDriverProvider {
    struct Unreachable: Error {}

    func openTransferDriver() async throws -> TransferDriverLease {
        throw Unreachable()
    }
}

// Writes a partial file, then waits for the test before it looks at the stop, as a plugin between two batches does.
final class GatedExportPlugin: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Gated"
    static let pluginVersion = "1.0"
    static let pluginDescription = "Test export"
    static let formatId = "gated"
    static let formatDisplayName = "Gated"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    let gate = TestGate()

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        try Data("partial".utf8).write(to: destination)
        await gate.enter()
        try progress.checkCancellation()
        return ExportFormatResult()
    }
}

enum TransferTestFolders {
    static func make(_ label: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}
