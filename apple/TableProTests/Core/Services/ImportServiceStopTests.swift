import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class StopDriver: PluginDriverStub, @unchecked Sendable {
    let hold = AsyncGate()
    let closing = AsyncGate()
    var holdClosingScope = false
    var rollbackFails = false
    var closeFails = false
    var heldText: String?
    var failingText: String?
    var implicitTransactions = false
    var commitLeavesOpen = false
    var commitFails = false
    var supportsTransactions = true
    var engines: [String: String] = [:]
    private let lock = NSLock()
    private var state = PluginSessionTransactionState.idle
    private var queries: [String] = []

    var events: [String] { lock.withLock { queries } }

    func setState(_ value: PluginSessionTransactionState) { lock.withLock { state = value } }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { queries.append(query) }
        if let heldText, query.contains(heldText) { await hold.wait() }
        if let failingText, query.contains(failingText) {
            throw DatabaseError.queryFailed("injected write failure")
        }
        if query.hasPrefix("BEGIN") { setState(.inTransaction) }
        if query.hasPrefix("COMMIT") {
            if commitFails { throw DatabaseError.queryFailed("injected commit failure") }
            if !commitLeavesOpen { setState(.idle) }
        }
        if query.hasPrefix("ROLLBACK") {
            if rollbackFails { throw DatabaseError.queryFailed("injected rollback failure") }
            setState(.idle)
        }
        if implicitTransactions, query.hasPrefix("INSERT") { setState(.inTransaction) }
        return .empty
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        PluginSessionScope(purpose: purpose, saved: [], applied: [])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        if holdClosingScope { await closing.wait() }
        if closeFails { throw DatabaseError.queryFailed("injected cleanup failure") }
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName) (id TEXT)"
    }

    func sessionTransactionState() async -> PluginSessionTransactionState { lock.withLock { state } }
    func switchDatabase(to database: String) async throws {}

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: engines[table] ?? "InnoDB")
    }
}

private final class StopRowsPlugin: ImportFormatPlugin {
    static let pluginName = "Stop Rows"
    static let pluginVersion = "1"
    static let pluginDescription = "Rows for stop tests"
    static let formatId = "stop-rows-test"
    static let formatDisplayName = "Rows"
    static let acceptedFileExtensions = ["rows"]
    static let iconName = "doc"
    static let requiresTargetTable = true
    private let configuration: RowImportRunner.Configuration

    required init() {
        configuration = RowImportRunner.Configuration(
            errorHandling: .stopAndRollback, wrapInTransaction: true, deleteExistingRows: false
        )
    }

    init(_ configuration: RowImportRunner.Configuration) {
        self.configuration = configuration
    }

    func performImport(source: any PluginImportSource, sink: any PluginImportDataSink,
                       progress: PluginImportProgress) async throws -> PluginImportResult {
        let lines = try String(contentsOf: source.fileURL(), encoding: .utf8).split(separator: "\n").map(String.init)
        var delivered = false
        let result = try await RowImportRunner.run(configuration: configuration, sink: sink, progress: progress) {
            guard !delivered else { return nil }
            delivered = true
            return lines.enumerated().map { (line: $0.offset + 1, row: ["id": .text($0.element)]) }
        }
        return PluginImportResult(executedStatements: result.inserted, executionTime: 0,
                                  skippedStatements: result.skipped, errors: result.errors)
    }
}

@MainActor
private final class StopFixture {
    let driver: StopDriver
    let adapter: PluginDriverAdapter
    let connection: DatabaseConnection
    let service: ImportService
    let plugin: StopRowsPlugin
    let format = UUID().uuidString
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    init(driver: StopDriver = StopDriver(), type: DatabaseType = .mysql,
         errorHandling: ImportErrorHandling = .stopAndRollback, wrapInTransaction: Bool = true) throws {
        plugin = StopRowsPlugin(.init(
            errorHandling: errorHandling, wrapInTransaction: wrapInTransaction, deleteExistingRows: false
        ))
        self.driver = driver
        connection = TestFixtures.makeConnection(database: "shop", type: type)
        adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.browseDatabase = "shop"
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        service = ImportService(connection: connection, gate: AlwaysAllowGate())
        PluginManager.shared.importPlugins[format] = plugin
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var scope: DatabaseScope { DatabaseScope(connectionId: connection.id, database: "shop", schema: nil) }

    func files(_ contents: [String], tables: [String]? = nil) throws -> [RowImportRunItem] {
        try contents.enumerated().map { index, text in
            let url = folder.appendingPathComponent("file\(index).rows")
            try Data(text.utf8).write(to: url)
            return RowImportRunItem(url: url, sourceName: url.lastPathComponent, formatId: format,
                                    targetTable: tables?[index] ?? "table\(index)",
                                    columnMapping: ["id": "id"], sourceFields: ["id"])
        }
    }

    func cleanup() {
        DatabaseManager.shared.removeSession(for: connection.id)
        PluginManager.shared.importPlugins[format] = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func pauseHeldWrite() async throws -> Int {
        await driver.hold.arrived(1)
        service.requestStop()
        #expect(service.run.currentPhase == .pausing)
        await driver.hold.open()
        try await waitUntil { self.service.run.questionIfPaused() != nil }
        return try #require(service.run.questionIfPaused()).generation
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ImportServiceStopTests {
    private let rollback = RowImportBatchPolicy(errorHandling: .stopAndRollback, wrapInTransaction: true)

    @Test("Stop during the last write rolls back instead of committing")
    func lastWrite() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        let file = try #require(fixture.files(["last"]).first)
        let task = Task {
            try await fixture.service.importFile(from: file.url, formatId: fixture.format, encoding: .utf8,
                                                 scope: fixture.scope, targetTable: file.targetTable,
                                                 columnMapping: file.columnMapping, sourceFields: file.sourceFields)
        }
        let generation = try await fixture.pauseHeldWrite()
        #expect(!fixture.driver.events.contains("COMMIT"))
        fixture.service.answerStop(.rollBack, generation: generation)
        await #expect(throws: PluginImportCancellationError.self) { try await task.value }
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(fixture.driver.events.contains("ROLLBACK"))
        #expect(fixture.service.stopResult.fate(for: 0) == .rolledBack)
    }

    @Test("A confirmation keeps the final commit parked until Continue")
    func continueFinalWrite() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        let files = try fixture.files(["first", "last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        #expect(fixture.driver.events.filter { $0 == "COMMIT" }.isEmpty)
        #expect(fixture.service.run.snapshot.effects[1]?.submittedRows == 1)
        fixture.service.answerStop(nil, generation: generation)
        let report = try await task.value
        #expect(report.ending == .completed)
        #expect(fixture.driver.events.filter { $0 == "BEGIN" }.count == 1)
        #expect(fixture.driver.events.filter { $0 == "COMMIT" }.count == 1)
        #expect(fixture.driver.events.filter { $0.hasPrefix("INSERT") }.count == 2)
    }

    @Test("A failed write under Stop and Commit does not commit earlier files after rollback Stop")
    func failedWriteBeforeStop() async throws {
        let fixture = try StopFixture(errorHandling: .stopAndCommit)
        defer { fixture.cleanup() }
        fixture.driver.heldText = "bad"
        fixture.driver.failingText = "bad"
        let files = try fixture.files(["first", "bad"])
        let policy = RowImportBatchPolicy(errorHandling: .stopAndCommit, wrapInTransaction: true)
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: policy) }
        let generation = try await fixture.pauseHeldWrite()
        fixture.service.answerStop(.rollBack, generation: generation)
        let report = try await task.value
        #expect(report.ending == .stopped(file: 1))
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(fixture.driver.events.contains("ROLLBACK"))
        #expect(report.stopResult?.ledger.errors.contains("injected write failure") == true)
        #expect(report.stopResult?.fate(for: 0) == .rolledBack)
    }

    @Test("Mixed InnoDB and MyISAM keep distinct fates")
    func mixedBatch() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.engines = ["table0": "InnoDB", "table1": "MyISAM"]
        fixture.driver.heldText = "last"
        let files = try fixture.files(["first", "last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        #expect(fixture.service.run.snapshot.question.contains("table1"))
        fixture.service.answerStop(.rollBack, generation: generation)
        let report = try await task.value
        #expect(report.stopResult?.fate(for: 0) == .rolledBack)
        #expect(report.stopResult?.fate(for: 1) == .kept)
    }

    @Test("Stop and Commit commits the owner once")
    func stopAndCommit() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        let files = try fixture.files(["first", "last"], tables: ["t", "t"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        #expect(fixture.service.run.snapshot.canChooseCommit)
        fixture.service.answerStop(.commit, generation: generation)
        let report = try await task.value
        #expect(fixture.driver.events.filter { $0 == "COMMIT" }.count == 1)
        #expect(!fixture.driver.events.contains("ROLLBACK"))
        #expect(report.stopResult?.fate(for: 0) == .committed)
        #expect(report.stopResult?.fate(for: 1) == .committed)
        #expect(report.stopResult?.ledger.effects[0]?.submittedRows == 1)
        #expect(report.stopResult?.ledger.effects[1]?.submittedRows == 1)
    }

    @Test("Existing user transactions are left open with wrapping on or off", arguments: [true, false])
    func existingTransaction(wrapped: Bool) async throws {
        let fixture = try StopFixture(wrapInTransaction: wrapped)
        defer { fixture.cleanup() }
        fixture.driver.setState(.inTransaction)
        fixture.driver.heldText = "last"
        let files = try fixture.files(["last"])
        let policy = RowImportBatchPolicy(errorHandling: .stopAndRollback, wrapInTransaction: wrapped)
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: policy) }
        let generation = try await fixture.pauseHeldWrite()
        fixture.service.answerStop(.rollBack, generation: generation)
        let report = try await task.value
        #expect(!fixture.driver.events.contains("BEGIN"))
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(!fixture.driver.events.contains("ROLLBACK"))
        #expect(report.stopResult?.fate(for: 0) == .openTransaction)
    }

    @Test("Unwrapped implicit transactions do not become kept rows")
    func implicitTransaction() async throws {
        let fixture = try StopFixture(wrapInTransaction: false)
        defer { fixture.cleanup() }
        fixture.driver.implicitTransactions = true
        fixture.driver.heldText = "last"
        let files = try fixture.files(["last"])
        let policy = RowImportBatchPolicy(errorHandling: .stopAndRollback, wrapInTransaction: false)
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: policy) }
        let generation = try await fixture.pauseHeldWrite()
        #expect(fixture.service.run.snapshot.question.contains("may stay"))
        fixture.service.answerStop(.rollBack, generation: generation)
        let report = try await task.value
        #expect(report.stopResult?.fate(for: 0) == .mayStay)
        #expect(report.stopResult?.text.contains("still open") == true)
        #expect(!fixture.driver.events.contains("ROLLBACK"))
    }

    @Test("An engine without transactions reports kept changes")
    func noTransactions() async throws {
        let driver = StopDriver()
        driver.supportsTransactions = false
        let fixture = try StopFixture(driver: driver)
        defer { fixture.cleanup() }
        driver.heldText = "last"
        let files = try fixture.files(["last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        fixture.service.answerStop(.rollBack, generation: generation)
        let report = try await task.value
        #expect(report.stopResult?.fate(for: 0) == .kept)
        #expect(!driver.events.contains("BEGIN"))
    }

    @Test("A commit that leaves the transaction open reports uncertainty")
    func nestedCommit() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        fixture.driver.commitLeavesOpen = true
        let files = try fixture.files(["last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        fixture.service.answerStop(.commit, generation: generation)
        let report = try await task.value
        #expect(report.stopResult?.fate(for: 0) == .mayStay)
        #expect(report.stopResult?.text.contains("still open") == true)
    }

    @Test("Failed commit retains its error and rolls back the owned transaction")
    func failedCommit() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        fixture.driver.commitFails = true
        let files = try fixture.files(["last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        let generation = try await fixture.pauseHeldWrite()
        fixture.service.answerStop(.commit, generation: generation)
        let report = try await task.value
        #expect(report.stopResult?.fate(for: 0) == .rolledBack)
        #expect(report.stopResult?.text.contains("injected commit failure") == true)
    }
}

extension ImportServiceStopTests {
    @Test("A file COMMIT queued after pause never runs under a rollback answer")
    func fileCommitParked() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        run.requestPause()
        let question = try #require(run.questionIfPaused())
        let pending = Task { try await sink.execute(statement: "COMMIT") }
        run.stop(.rollBack, generation: question.generation)
        await #expect(throws: PluginImportCancellationError.self) { try await pending.value }
        try await sink.rollbackTransaction()
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .rolledBack)
    }

    @Test("A file COMMIT already in flight makes the paused question conservative")
    func fileCommitInFlight() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "COMMIT"
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        let pending = Task { try await sink.execute(statement: "COMMIT") }
        await fixture.driver.hold.arrived(1)
        run.requestPause()
        await fixture.driver.hold.open()
        try await pending.value
        let question = try #require(run.questionIfPaused())
        #expect(question.ledger.question.contains("may stay"))
        #expect(!question.ledger.canChooseCommit)
        run.stop(.rollBack, generation: question.generation)
        try await sink.rollbackTransaction()
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .mayStay)
    }

    @Test("A statement paused before admission runs once after Continue")
    func pausedStatementRunsOnce() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql, importRun: run)
        try await sink.prepareImportRun()
        run.requestPause()
        let question = try #require(run.questionIfPaused())
        let pending = Task { try await sink.execute(statement: "INSERT INTO t VALUES (1)") }
        #expect(fixture.driver.events.isEmpty)
        run.resume(generation: question.generation)
        try await pending.value
        #expect(fixture.driver.events == ["INSERT INTO t VALUES (1)"])
        #expect(run.snapshot.effects[0]?.statements == 1)
    }

    @Test("SQL Server GO execution never promises a complete commit")
    func sqlServerIsConservative() async throws {
        let fixture = try StopFixture(type: .mssql)
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mssql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        run.requestPause()
        let question = try #require(run.questionIfPaused())
        #expect(question.ledger.unseenStatements)
        #expect(!question.ledger.canChooseCommit)
        #expect(question.ledger.question.contains("may stay"))
        run.stop(.rollBack, generation: question.generation)
        try await sink.rollbackTransaction()
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .mayStay)
    }

    @Test("An aborted owned transaction rolls back even under commit intent")
    func abortedCommit() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        fixture.driver.setState(.abortedTransaction)
        run.stop(.commit)
        try await sink.commitTransaction()
        #expect(fixture.driver.events.last == "ROLLBACK")
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .rolledBack)
    }

    @Test("Task cancellation outside a parked call refuses normal COMMIT")
    func taskCancellationDuringWrite() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "last"
        let files = try fixture.files(["last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        await fixture.driver.hold.arrived(1)
        task.cancel()
        await fixture.driver.hold.open()
        let report = try await task.value
        #expect(report.ending == .stopped(file: 0))
        #expect(!fixture.driver.events.contains("COMMIT"))
        #expect(fixture.driver.events.contains("ROLLBACK"))
    }
}

extension ImportServiceStopTests {
    @Test("A stopped partial handoff retains the completed sub-batch count")
    func partialHandoff() async throws {
        let fixture = try StopFixture(type: .oracle)
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .oracle,
                                         targetTable: "t", importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        let task = Task {
            try await sink.insertRows(columns: ["id"], values: [[.text("first")], [.text("second")]]) { _ in
                run.requestPause()
            }
        }
        try await waitUntil { run.questionIfPaused() != nil }
        let question = try #require(run.questionIfPaused())
        #expect(question.ledger.effects[0]?.submittedRows == 1)
        run.stop(.rollBack, generation: question.generation)
        await #expect(throws: PluginImportCancellationError.self) { try await task.value }
        try await sink.rollbackTransaction()
        #expect(fixture.driver.events.filter { $0.hasPrefix("INSERT") }.count == 1)
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .rolledBack)
    }

    @Test("A successful ignored insert reports submitted rows, never affected rows")
    func ignoredInsertCount() async throws {
        let fixture = try StopFixture(type: .sqlite)
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .sqlite,
                                         targetTable: "t", columnMapping: ["id": "id"], importRun: run)
        try await sink.prepareImportRun()
        try await sink.insertRow(["id": .text("already-present")])
        let result = ImportStopResult(ledger: run.snapshot)
        #expect(result.ledger.effects[0]?.submittedRows == 1)
        #expect(result.fileText(for: 0).contains("row submitted in a completed write"))
    }
}


extension ImportServiceStopTests {
    @Test("A retry DELETE cannot run while paused or after Stop")
    func preparationDeleteIsGated() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = fixture.service.run
        var planner = NewTableImportPlanner()
        planner.recordCreated(TableScope(table: "t", in: fixture.scope), createTableSQL: "CREATE TABLE t (id TEXT)")
        let definition = PluginCreateTableDefinition(tableName: "t", columns: [], primaryKeyColumns: [])
        let maker = RowImportTableMaker(connection: fixture.connection, gate: AlwaysAllowGate())
        run.requestPause()
        let task = Task {
            try await maker.prepare([definition], scope: fixture.scope, planner: planner, importRun: run) { _, _ in }
        }
        try await waitUntil { run.waitingCallCount > 0 }
        #expect(!fixture.driver.events.contains { $0.hasPrefix("DELETE") })
        fixture.service.answerStop(.rollBack, generation: try #require(run.questionIfPaused()).generation)
        await #expect(throws: PluginImportCancellationError.self) { try await task.value }
        #expect(!fixture.driver.events.contains { $0.hasPrefix("DELETE") })
        #expect(run.snapshot.preparations.isEmpty)
    }

    @Test("A completed retry DELETE is recorded outside the later row transaction")
    func preparationDeleteIsReported() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.heldText = "DELETE"
        let run = fixture.service.run
        var planner = NewTableImportPlanner()
        planner.recordCreated(TableScope(table: "t", in: fixture.scope), createTableSQL: "CREATE TABLE t (id TEXT)")
        let definition = PluginCreateTableDefinition(tableName: "t", columns: [], primaryKeyColumns: [])
        let maker = RowImportTableMaker(connection: fixture.connection, gate: AlwaysAllowGate())
        let task = Task {
            try await maker.prepare([definition], scope: fixture.scope, planner: planner, importRun: run) { _, _ in }
        }
        await fixture.driver.hold.arrived(1)
        fixture.service.requestStop()
        #expect(run.questionIfPaused() == nil)
        await fixture.driver.hold.open()
        _ = try await task.value
        let question = try #require(run.questionIfPaused())
        #expect(question.ledger.question.contains("table cleared"))
        #expect(question.ledger.question.contains("changes kept"))
        fixture.service.answerStop(.rollBack, generation: question.generation)
        let files = try fixture.files(["new"], tables: ["t"])
        let report = try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback)
        #expect(report.stopResult?.text.contains("table cleared") == true)
        #expect(report.stopResult?.text.contains("changes kept") == true)
        #expect(!fixture.driver.events.contains { $0.hasPrefix("INSERT") })
    }

    @Test("Stop during final cleanup waits for an answer before finishing")
    func finalCleanupPause() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.holdClosingScope = true
        let files = try fixture.files(["last"])
        let task = Task { try await fixture.service.importFiles(files, scope: fixture.scope, policy: rollback) }
        await fixture.driver.closing.arrived(1)
        fixture.service.requestStop()
        #expect(fixture.service.run.currentPhase == .pausing)
        await fixture.driver.closing.open()
        try await waitUntil { fixture.service.run.waitingCallCount > 0 }
        let question = try #require(fixture.service.run.questionIfPaused())
        #expect(question.ledger.question.contains("already committed"))
        fixture.service.answerStop(.rollBack, generation: question.generation)
        let report = try await task.value
        #expect(report.ending == .stopped(file: 0))
        #expect(report.stopResult?.fate(for: 0) == .committed)
    }

    @Test("Commit intent replaces a policy rollback that was parked")
    func commitReplacesParkedRollback() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = fixture.service.run
        let owner = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql,
                                          targetTable: "t", columnMapping: ["id": "id"], importRun: run)
        try await owner.prepareImportRun()
        try await owner.beginTransaction()
        try await owner.insertRow(["id": .text("first")])
        run.requestPause()
        let task = Task { await fixture.service.finishOwner(owner, commit: false) }
        try await waitUntil { run.waitingCallCount > 0 }
        fixture.service.answerStop(.commit, generation: try #require(run.questionIfPaused()).generation)
        #expect(await task.value == nil)
        #expect(fixture.driver.events.contains("COMMIT"))
        #expect(!fixture.driver.events.contains("ROLLBACK"))
        #expect(ImportStopResult(ledger: run.snapshot).fate(for: 0) == .committed)
    }

    @Test("A transaction the file opens after COMMIT is never finalized by the import", arguments: [false, true])
    func replacementTransactionIsUnowned(stopping: Bool) async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mysql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "COMMIT")
        try await sink.execute(statement: "BEGIN")
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        if stopping {
            run.stop(.rollBack)
            try await sink.rollbackTransaction()
        } else {
            try await sink.commitTransaction()
        }
        #expect(fixture.driver.events.filter { $0 == "COMMIT" }.count == 1)
        #expect(!fixture.driver.events.contains("ROLLBACK"))
        #expect(run.snapshot.currentState == .open)
        #expect(run.snapshot.holder == .none)
    }

    @Test("A single-file failure includes rollback and cleanup failures")
    func failureCarriesCleanupErrors() async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        fixture.driver.failingText = "bad"
        fixture.driver.rollbackFails = true
        fixture.driver.closeFails = true
        let file = try #require(fixture.files(["bad"]).first)
        var failure: (any Error)?
        do {
            _ = try await fixture.service.importFile(from: file.url, formatId: fixture.format, encoding: .utf8,
                                                     scope: fixture.scope, targetTable: file.targetTable,
                                                     columnMapping: file.columnMapping, sourceFields: file.sourceFields)
            Issue.record("The failed write must be reported")
        } catch { failure = error }
        let text = TransferResultAlert.importFailureSummary(error: failure, result: fixture.service.stopResult)
        #expect(text.contains("injected write failure"))
        #expect(text.contains("injected rollback failure"))
        #expect(text.contains("injected cleanup failure"))
        #expect(text.contains("still open"))
    }
}


extension ImportServiceStopTests {
    @Test("An opaque SQL Server batch cannot leave finalization authority on its replacement transaction",
          arguments: [false, true])
    func opaqueBatchRevokesAuthority(stopping: Bool) async throws {
        let fixture = try StopFixture(type: .mssql)
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mssql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "COMMIT; BEGIN TRANSACTION; INSERT INTO t VALUES (1)")
        if stopping { run.stop(.rollBack); try await sink.rollbackTransaction() }
        else { try await sink.commitTransaction() }
        #expect(!fixture.driver.events.contains { $0.hasPrefix("ROLLBACK") })
        #expect(fixture.driver.events.filter { $0.hasPrefix("COMMIT") }.count == 1)
        #expect(run.snapshot.holder == .none)
        #expect(run.snapshot.currentState == .open)
        #expect(ImportStopResult(ledger: run.snapshot).completionNotes.contains("still open"))
    }

    @Test("Normal completion surfaces a transaction left open after opaque SQL")
    func completionShowsPendingTransaction() async throws {
        let fixture = try StopFixture(type: .mssql)
        defer { fixture.cleanup() }
        let run = ImportRun()
        let sink = ImportDataSinkAdapter(driver: fixture.adapter, databaseType: .mssql, importRun: run)
        try await sink.prepareImportRun()
        try await sink.beginTransaction()
        try await sink.execute(statement: "INSERT INTO t VALUES (1)")
        try await sink.commitTransaction()
        let result = ImportStopResult(ledger: run.snapshot)
        #expect(result.completionNotes.contains("still open"))
        let report = RowImportBatchReport(files: [], outcomes: [], ending: .completed, transaction: .untracked,
                                         executionTime: 0, stopResult: result)
        #expect(TransferResultAlert.batchImportSummary(report).contains("still open"))
    }

    @Test("Stop after a preparation failure preserves the error but reports cancellation", arguments: [false, true])
    func stopAfterPreparationFailure(clearing: Bool) async throws {
        let fixture = try StopFixture()
        defer { fixture.cleanup() }
        let run = fixture.service.run
        let keyword = clearing ? "DELETE" : "CREATE"
        fixture.driver.heldText = keyword
        fixture.driver.failingText = keyword
        var planner = NewTableImportPlanner()
        if clearing {
            planner.recordCreated(TableScope(table: "t", in: fixture.scope), createTableSQL: "CREATE TABLE t (id TEXT)")
        }
        let definition = PluginCreateTableDefinition(tableName: "t", columns: [], primaryKeyColumns: [])
        let maker = RowImportTableMaker(connection: fixture.connection, gate: AlwaysAllowGate())
        let task = Task {
            try await maker.prepare([definition], scope: fixture.scope, planner: planner, importRun: run) { _, _ in }
        }
        await fixture.driver.hold.arrived(1)
        fixture.service.requestStop()
        await fixture.driver.hold.open()
        try await waitUntil { run.waitingCallCount > 0 }
        fixture.service.answerStop(.rollBack, generation: try #require(run.questionIfPaused()).generation)
        await #expect(throws: PluginImportCancellationError.self) { try await task.value }
        #expect(run.snapshot.errors.contains("injected write failure"))
        #expect(fixture.service.stopResult.text.contains("failed before row import"))
    }

    @Test("Long failure descriptions stay bounded on screen and remain whole in Copy Details")
    func boundedFailureDetails() {
        let marker = "last-error-detail"
        let long = String(repeating: String(repeating: "x", count: 300) + "\n", count: 100) + marker
        let error = DatabaseError.queryFailed(long)
        var ledger = ImportLedger()
        ledger.errors = [long]
        ledger.cleanupErrors = ["rollback failed"]
        ledger.currentState = .open
        let result = ImportStopResult(ledger: ledger)
        let display = TransferResultAlert.importFailureDisplay(error: error, result: result)
        #expect(display.utf16.count < TransferResultAlert.shownErrorLengthLimit + 100)
        #expect(display.components(separatedBy: "\n").count <= TransferResultAlert.shownErrorLineLimit + 1)
        #expect(display.contains("still open"))
        #expect(display.contains("rollback failed"))
        #expect(result.details.contains(marker))
    }
}


extension ImportServiceStopTests {
    @Test("A batch's open-transaction warning precedes preparation details", arguments: [false, true])
    func batchWarningStaysVisible(stopped: Bool) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let file = RowImportRunItem(url: URL(fileURLWithPath: "/tmp/input.csv"), sourceName: "input.csv",
                                   formatId: "csv", targetTable: "t", columnMapping: [:], sourceFields: [])
        let error = DatabaseError.queryFailed("write failed")
        var ledger = ImportLedger()
        ledger.currentState = .open
        ledger.cleanupErrors = ["rollback failed"]
        for index in 0..<10 {
            ledger.preparations[UUID()] = ImportPreparationEffect(table: TableScope(table: "t\(index)", in: scope),
                                                                 clearing: false, completed: true)
        }
        let report = RowImportBatchReport(files: [file], outcomes: [.failed(error, rowsBefore: 0)],
                                         ending: stopped ? .stopped(file: 0) : .failed(file: 0),
                                         transaction: .untracked, executionTime: 0,
                                         stopResult: ImportStopResult(ledger: ledger))
        let shown = TransferResultAlert.shownErrors(TransferResultAlert.batchImportSummary(report))
        #expect(shown.hasPrefix("A transaction is still open"))
        #expect(shown.contains("rollback failed"))
    }
}
