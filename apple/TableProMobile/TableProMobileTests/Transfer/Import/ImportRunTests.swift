import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import Testing

@testable import TableProMobile

@MainActor
private final class FakeSessionHost: TransferSessionHost {
    let driver: any DatabaseDriver
    private(set) var trackedRuns = 0
    private(set) var sessionChecks = 0
    private(set) var changedKinds: [SQLCatalogObjectKinds] = []
    private(set) var sessionEffects: [SessionLocalStatements.Effect] = []
    private(set) var placementFollows: [[Bool]] = []

    init(driver: any DatabaseDriver) {
        self.driver = driver
    }

    var transferDriver: Result<any DatabaseDriver, AppError> { .success(driver) }
    var transferDatabase: String?

    // As `ConnectionCoordinator.track(failed:)` does: a value the test calls failed sends the session to its check.
    private(set) var aloneRuns = 0

    func trackTransfer<T: Sendable>(
        alone: Bool,
        failed: @Sendable (T) -> Bool,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        trackedRuns += 1
        if alone { aloneRuns += 1 }
        let value = try await work()
        if failed(value) { sessionChecks += 1 }
        return value
    }

    func noteTransferChangedCatalog(_ kinds: SQLCatalogObjectKinds) {
        changedKinds.append(kinds)
    }

    func noteTransferSessionEffect(_ effect: SessionLocalStatements.Effect, on driver: any DatabaseDriver) {
        sessionEffects.append(effect)
    }

    func followTransferPlacement(movesDatabase: Bool, movesSchema: Bool) async {
        placementFollows.append([movesDatabase, movesSchema])
    }

    func abandonTransferSession() async {}
}

struct ImportRunTests {
    private let directory: URL

    init() throws {
        directory = try TransferTestFolders.make("import-run")
    }

    private func database() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(source: .file(directory.appendingPathComponent("run.db")), openMode: .createNew)
        try await driver.connect()
        return driver
    }

    private func staged(_ name: String, _ text: String) throws -> StagedImportFile {
        let folder = try TransferFiles.makeImportFolder(in: directory)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return StagedImportFile(url: url, folder: folder, originalName: name)
    }

    private func request(
        _ file: StagedImportFile, formatId: String, target: RowImportTarget? = nil, connectionId: UUID = UUID()
    ) -> ImportRequest {
        ImportRequest(
            formatId: formatId, file: file, connectionId: connectionId, connectionName: "Local", databaseType: .sqlite,
            database: nil, safeModeLevel: .off, target: target
        )
    }

    @Test("A SQL file runs on the session inside the host's tracking and tells it the catalog moved")
    func sqlFileRunsTracked() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("seed.sql", "CREATE TABLE t (a INTEGER);\nINSERT INTO t VALUES (1);\nINSERT INTO t VALUES (2);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        #expect(outcome.ending == .completed)
        #expect(outcome.executedStatements == 3)
        #expect(try await driver.execute(query: "SELECT count(*) FROM t").rows.first?.first == "2")
        #expect(await host.trackedRuns == 1)
        #expect(await host.aloneRuns == 1)
        #expect(await host.changedKinds == [.everything])
    }

    @Test("A failing statement rolls back the import's own transaction and reports it as failed")
    func failedSQLFileRollsBack() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE t (a INTEGER)")
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("bad.sql", "INSERT INTO t VALUES (1);\nINSERT INTO missing VALUES (2);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        guard case .failed = outcome.ending else {
            Issue.record("expected a failed import, got \(outcome.ending)")
            return
        }
        #expect(outcome.transaction == .rolledBack)
        #expect(try await driver.execute(query: "SELECT count(*) FROM t").rows.first?.first == "0")
    }

    @Test("A failed import still returns its outcome, and the host checks the session it ran on")
    func failedImportReachesTheSessionCheck() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE t (a INTEGER)")
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("bad.sql", "INSERT INTO t VALUES (1);\nINSERT INTO missing VALUES (2);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        guard case .failed = outcome.ending else {
            Issue.record("expected a failed import, got \(outcome.ending)")
            return
        }
        #expect(await host.sessionChecks == 1)
    }

    @Test("A completed import leaves the session alone")
    func completedImportSkipsTheSessionCheck() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("seed.sql", "CREATE TABLE t (a INTEGER);\nINSERT INTO t VALUES (1);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        #expect(outcome.ending == .completed)
        #expect(await host.sessionChecks == 0)
    }

    @Test("Which endings send the session to its check", arguments: [
        (DataImportOutcome.Ending.failed("gone"), ImportTransactionEnding.rolledBack, true),
        (.completed, .committed, false),
        (.completed, .endedByServer, true),
        (.stopped, .rolledBack, false),
        (.stopped, .endedByServer, true),
        (.expired, .endedByServer, false)
    ])
    func endingsThatCheckTheSession(
        _ ending: DataImportOutcome.Ending, _ transaction: ImportTransactionEnding, _ checks: Bool
    ) {
        let outcome = DataImportOutcome(
            ending: ending, transaction: transaction, tally: nil, executedStatements: 0, skippedStatements: 0,
            errors: [], createdTable: false, catalogChanges: []
        )
        #expect(outcome.mayHaveLostSession == checks)
    }

    @Test("Read-Only refuses the run before it reaches the session")
    func readOnlyRefusesBeforeWriting() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("seed.sql", "CREATE TABLE t (a INTEGER);\n")
        let refused = ImportRequest(
            formatId: "sql", file: file, connectionId: UUID(), connectionName: "Local", databaseType: .sqlite,
            database: nil, safeModeLevel: .readOnly, target: nil
        )
        let run = ImportRun(request: refused, plugin: MobileImportFormats.sql, host: host)

        await #expect(throws: MobileTransferRefusal.self) {
            _ = try await run.run { _ in }
        }
        #expect(await host.trackedRuns == 0)
    }

    @Test("A stop before the run starts writes nothing")
    func stopBeforeStartWritesNothing() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("seed.sql", "CREATE TABLE t (a INTEGER);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)
        run.stop(.rollBack)

        await #expect(throws: CancellationError.self) {
            _ = try await run.run { _ in }
        }
        #expect(try await driver.fetchTables(schema: nil).isEmpty)
    }

    // Goes through the SQLite engine's own write dialect, so it also covers the engine lane's conformance.
    @Test("CSV rows land in a new table the run makes first, and a retry clears and reuses it")
    func csvIntoNewTable() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let planner = ImportTablePlanner()
        let definition = PluginCreateTableDefinition(
            tableName: "people",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "name", dataType: "TEXT")
            ],
            primaryKeyColumns: ["id"]
        )
        let target = RowImportTarget(
            table: "people", schema: nil, columnMapping: ["id": "id", "name": "name"], sourceFields: ["id", "name"],
            newTable: definition
        )

        let connectionId = UUID()
        for _ in 0..<2 {
            let file = try staged("people.csv", "id,name\n1,Ada\n2,Bo\n")
            let run = ImportRun(
                request: request(file, formatId: "csv", target: target, connectionId: connectionId),
                plugin: MobileImportFormats.csv,
                host: host, planner: planner
            )
            let outcome = try await run.run { _ in }
            #expect(outcome.ending == .completed)
            #expect(outcome.tally?.inserted == 2)
        }

        #expect(try await driver.execute(query: "SELECT count(*) FROM people").rows.first?.first == "2")
        #expect(await host.changedKinds == [.tables])
    }

    @Test("A retry into the table an earlier import made empties it inside its own transaction, so a failing retry keeps the rows")
    func failedRetryKeepsTheFirstRunsRows() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let planner = ImportTablePlanner()
        let definition = PluginCreateTableDefinition(
            tableName: "people",
            columns: [
                PluginColumnDefinition(name: "id", dataType: "INTEGER", isNullable: false, isPrimaryKey: true),
                PluginColumnDefinition(name: "name", dataType: "TEXT")
            ],
            primaryKeyColumns: ["id"]
        )
        let target = RowImportTarget(
            table: "people", schema: nil, columnMapping: ["id": "id", "name": "name"], sourceFields: ["id", "name"],
            newTable: definition
        )
        let connectionId = UUID()
        func importing(_ text: String) async throws -> DataImportOutcome {
            let run = ImportRun(
                request: request(try staged("people.csv", text), formatId: "csv", target: target, connectionId: connectionId),
                plugin: MobileImportFormats.csv,
                host: host, planner: planner
            )
            return try await run.run { _ in }
        }

        #expect(try await importing("id,name\n1,Ada\n2,Bo\n").ending == .completed)
        let retry = try await importing("id,name\n3,Cy\n3,Dup\n")

        guard case .failed = retry.ending else {
            Issue.record("expected the retry to fail, got \(retry.ending)")
            return
        }
        #expect(retry.transaction == .rolledBack)
        let names = try await driver.execute(query: "SELECT name FROM people ORDER BY id").rows.compactMap { $0.first ?? nil }
        #expect(names == ["Ada", "Bo"])
    }

    @Test("A second import on the connection waits for the one running to end, instead of joining its transaction")
    func importsOnOneConnectionTakeTurns() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE t (a INTEGER)")
        let host = await FakeSessionHost(driver: driver)
        let turns = ImportTurns()
        let connectionId = UUID()
        let running = ImportTurns.Ticket(connectionId: connectionId)
        try await turns.take(running)
        let file = try staged("seed.sql", "INSERT INTO t VALUES (1);\n")
        let run = ImportRun(
            request: request(file, formatId: "sql", connectionId: connectionId), plugin: MobileImportFormats.sql,
            host: host, turns: turns
        )

        let second = Task { try await run.run { _ in } }
        try await waitUntil { turns.waiting(on: connectionId) == 1 }
        #expect(await host.trackedRuns == 0)
        turns.release(running)

        let outcome = try await second.value
        #expect(outcome.ending == .completed)
        #expect(await host.trackedRuns == 1)
        let next = ImportTurns.Ticket(connectionId: connectionId)
        #expect(await BoundedCall.result(within: .seconds(5)) { (try? await turns.take(next)) != nil } == true)
        turns.release(next)
    }

    @Test("A stop while the import waits for its turn ends it before it touches the session")
    func stopWhileWaitingForTheTurn() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE t (a INTEGER)")
        let host = await FakeSessionHost(driver: driver)
        let turns = ImportTurns()
        let connectionId = UUID()
        let running = ImportTurns.Ticket(connectionId: connectionId)
        try await turns.take(running)
        let file = try staged("seed.sql", "INSERT INTO t VALUES (1);\n")
        let run = ImportRun(
            request: request(file, formatId: "sql", connectionId: connectionId), plugin: MobileImportFormats.sql,
            host: host, turns: turns
        )

        let second = Task { try await run.run { _ in } }
        try await waitUntil { turns.waiting(on: connectionId) == 1 }
        run.stop(.rollBack)

        await #expect(throws: CancellationError.self) {
            _ = try await second.value
        }
        #expect(turns.waiting(on: connectionId) == 0)
        #expect(await host.trackedRuns == 0)
        #expect(try await driver.execute(query: "SELECT count(*) FROM t").rows.first?.first == "0")
        turns.release(running)
    }

    @Test("A SQL file's temporary table is recorded on the session and the window follows where the file left it")
    func sqlFileSessionEffectsReachTheWindow() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("temp.sql", "CREATE TEMP TABLE scratch (a INTEGER);\nINSERT INTO scratch VALUES (1);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        #expect(outcome.ending == .completed)
        #expect(await host.sessionEffects.map(\.temporaryTables) == [["scratch"]])
        #expect(await host.placementFollows.count == 1)
    }

    @Test("A SQL file that fails on its USE still has the window follow the session's database")
    func failedSQLFileStillFollowsTheSession() async throws {
        let driver = try await database()
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("use.sql", "USE other_db;\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        guard case .failed = outcome.ending else {
            Issue.record("expected a failed import, got \(outcome.ending)")
            return
        }
        #expect(await host.sessionEffects.first?.usesDatabase == true)
        #expect(await host.placementFollows.first == [true, true])
    }

    @Test("A row import leaves the session's placement to the window")
    func rowImportDoesNotFollowTheSession() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        let host = await FakeSessionHost(driver: driver)
        let target = RowImportTarget(
            table: "people", schema: nil, columnMapping: ["id": "id", "name": "name"], sourceFields: ["id", "name"]
        )
        let file = try staged("people.csv", "id,name\n1,Ada\n")
        let run = ImportRun(request: request(file, formatId: "csv", target: target), plugin: MobileImportFormats.csv, host: host)

        _ = try await run.run { _ in }

        #expect(await host.sessionEffects.isEmpty)
        #expect(await host.placementFollows.isEmpty)
    }

    @Test("A row import whose session moved to another database since the sheet opened is refused before it writes")
    func movedSessionRefusesTheImport() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        let host = await FakeSessionHost(driver: driver)
        await MainActor.run { host.transferDatabase = "archive" }
        let target = RowImportTarget(
            table: "people", schema: nil, columnMapping: ["id": "id", "name": "name"], sourceFields: ["id", "name"]
        )
        let file = try staged("people.csv", "id,name\n1,Ada\n")
        let moved = ImportRequest(
            formatId: "csv", file: file, connectionId: UUID(), connectionName: "Local", databaseType: .sqlite,
            database: "main", safeModeLevel: .off, target: target
        )
        let run = ImportRun(request: moved, plugin: MobileImportFormats.csv, host: host)

        await #expect(throws: MobileTransferRefusal(reason: ImportRun.sessionMovedMessage)) {
            _ = try await run.run { _ in }
        }
        #expect(try await driver.execute(query: "SELECT count(*) FROM people").rows.first?.first == "0")
    }

    @Test("A row import on the session's own database goes ahead")
    func sameDatabaseImports() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        let host = await FakeSessionHost(driver: driver)
        await MainActor.run { host.transferDatabase = "main" }
        let target = RowImportTarget(
            table: "people", schema: nil, columnMapping: ["id": "id", "name": "name"], sourceFields: ["id", "name"]
        )
        let file = try staged("people.csv", "id,name\n1,Ada\n")
        let request = ImportRequest(
            formatId: "csv", file: file, connectionId: UUID(), connectionName: "Local", databaseType: .sqlite,
            database: "main", safeModeLevel: .off, target: target
        )

        let outcome = try await ImportRun(request: request, plugin: MobileImportFormats.csv, host: host).run { _ in }

        #expect(outcome.ending == .completed)
    }

    @Test("A SQL file that rolls back the import's transaction and then inserts keeps that row and says so")
    func sqlFileRollbackThenInsertIsReported() async throws {
        let driver = try await database()
        _ = try await driver.execute(query: "CREATE TABLE t (a INTEGER)")
        let host = await FakeSessionHost(driver: driver)
        let file = try staged("rollback.sql", "INSERT INTO t VALUES (1);\nROLLBACK;\nINSERT INTO t VALUES (2);\n")
        let run = ImportRun(request: request(file, formatId: "sql"), plugin: MobileImportFormats.sql, host: host)

        let outcome = try await run.run { _ in }

        #expect(outcome.ending == .completed)
        #expect(outcome.transaction == .committed)
        #expect(try await driver.execute(query: "SELECT group_concat(a) FROM t").rows.first?.first == "2")
    }
}
