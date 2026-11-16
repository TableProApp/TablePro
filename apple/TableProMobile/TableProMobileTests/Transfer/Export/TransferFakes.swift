import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting
import UIKit

// A driver that answers export reads from scripted rows and records every statement it is sent.
final class RecordingTransferDriver: DatabaseDriver, ExportRowStreaming, CatalogQuerying, @unchecked Sendable {
    // How a catalog read behaves: answered at once, held until `cancelCurrentQuery`, or held with the stop itself
    // never answering either, as a driver blocked on a dead socket.
    enum ReadStall {
        case none
        case untilInterrupted
        case unresponsive
    }

    struct Interrupted: Error {}

    private let lock = NSLock()
    private var sent: [String] = []
    private var readOnlyFlags: [Bool] = []
    private var stalledReads: [CheckedContinuation<Void, any Error>] = []
    private var stalledStops: [CheckedContinuation<Void, Never>] = []
    private var stallObservers: [CheckedContinuation<Void, Never>] = []
    private var interruptCount = 0
    var scriptedRows: [String: (header: PluginStreamHeader, rows: [PluginRow])] = [:]
    var transactionState: DriverTransactionState = .idle
    var supportsSchemas = false
    var currentSchema: String?
    var schemaSwitchFailure: (any Error)?
    var enforcesReadOnlyMode = false
    var stall = ReadStall.none
    var exportCatalog: (any MobileExportCatalog)?
    var literalEscaping: (@Sendable (String) -> String)?
    private(set) var disconnected = false

    var executed: [String] { lock.withLock { sent } }
    var exportReadOnlyFlags: [Bool] { lock.withLock { readOnlyFlags } }
    var interrupts: Int { lock.withLock { interruptCount } }
    var isDisconnected: Bool { lock.withLock { disconnected } }

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
        if stall != .none {
            try await withCheckedThrowingContinuation { continuation in
                let observers = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                    stalledReads.append(continuation)
                    defer { stallObservers = [] }
                    return stallObservers
                }
                observers.forEach { $0.resume() }
            }
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func waitUntilStalled() async {
        await withCheckedContinuation { observer in
            let stalled = lock.withLock { () -> Bool in
                guard stalledReads.isEmpty else { return true }
                stallObservers.append(observer)
                return false
            }
            if stalled { observer.resume() }
        }
    }

    // Lets every held read and stop go, so a test leaves no continuation behind.
    func endStall() {
        let (reads, stops) = lock.withLock { () -> ([CheckedContinuation<Void, any Error>], [CheckedContinuation<Void, Never>]) in
            defer {
                stalledReads = []
                stalledStops = []
            }
            return (stalledReads, stalledStops)
        }
        reads.forEach { $0.resume(throwing: Interrupted()) }
        stops.forEach { $0.resume() }
    }

    func escapeStringLiteral(_ value: String) -> String {
        literalEscaping?(value) ?? SQLQuoting.stringLiteralBody(value)
    }

    func connect() async throws {}
    func disconnect() async throws { lock.withLock { disconnected = true } }
    func ping() async throws -> Bool { true }
    func execute(query: String) async throws -> QueryResult {
        record(query)
        return QueryResult(columns: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func cancelCurrentQuery() async throws {
        let mode = lock.withLock { () -> ReadStall in
            interruptCount += 1
            return stall
        }
        switch mode {
        case .none:
            return
        case .untilInterrupted:
            let reads = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                defer { stalledReads = [] }
                return stalledReads
            }
            reads.forEach { $0.resume(throwing: Interrupted()) }
        case .unresponsive:
            await withCheckedContinuation { stop in
                lock.withLock { stalledStops.append(stop) }
            }
        }
    }
    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    func switchSchema(to name: String) async throws {
        record("switchSchema(\(name))")
        if let schemaSwitchFailure { throw schemaSwitchFailure }
    }
    func fetchSchemas() async throws -> [String] { [] }
    var supportsTransactions: Bool { true }
    func beginTransaction() async throws { record("BEGIN") }
    func commitTransaction() async throws { record("COMMIT") }
    func rollbackTransaction() async throws { record("ROLLBACK") }
    func sessionTransactionState() async -> DriverTransactionState { transactionState }
    var serverVersion: String? { nil }
}

extension RecordingTransferDriver: MobileTransferEngine {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog {
        guard let exportCatalog else { throw MobileTransferRefusal(reason: "No catalog scripted") }
        return exportCatalog
    }
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

// Hands a dedicated connection and the window's session out separately, so a test sees which one a read took.
struct SplitDriverProvider: TransferDriverProvider {
    let dedicated: any DatabaseDriver
    let session: any DatabaseDriver

    func openTransferDriver() async throws -> TransferDriverLease {
        TransferDriverLease(driver: dedicated, isSessionDriver: false) {}
    }

    func openSessionDriver() async throws -> TransferDriverLease {
        TransferDriverLease(driver: session, isSessionDriver: true) {}
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

// Reads through the data source's `execute`, which the driver may hold, as a format's snapshot BEGIN does.
final class ExecutingExportPlugin: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Executing"
    static let pluginVersion = "1.0"
    static let pluginDescription = "Test export"
    static let formatId = "executing"
    static let formatDisplayName = "Executing"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        try Data("partial".utf8).write(to: destination)
        _ = try await dataSource.execute(query: "SELECT pg_sleep(3600)")
        try progress.checkCancellation()
        return ExportFormatResult()
    }
}

// A format with one setting kept under a test-only storage key, so changing it touches no shipped format's defaults.
final class SettingsProbePlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    struct Settings: Codable, Equatable {
        var compresses = false
    }

    static let pluginName = "Settings Probe"
    static let pluginVersion = "1.0"
    static let pluginDescription = "Test export"
    static let formatId = "settings-probe"
    static let formatDisplayName = "Settings Probe"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"
    static let settingsStorageId = "tests.settings-probe"

    var settings = Settings() {
        didSet { saveSettings() }
    }

    required init() {}

    var currentFileExtension: String { settings.compresses ? "txt.gz" : "txt" }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        ExportFormatResult()
    }
}

@MainActor
final class RecordingAsserter: BackgroundTaskAsserting {
    let identifier = UIBackgroundTaskIdentifier(rawValue: 11)
    private(set) var names: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (() -> Void)?

    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        names.append(name)
        self.expirationHandler = expirationHandler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    func fireExpiration() {
        expirationHandler?()
    }
}

@MainActor
final class FakeHold: TransferHolding {
    private(set) var releases = 0

    func release() {
        releases += 1
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
