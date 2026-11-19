//
//  LibPQPipelineTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LibPQPipelineTests {
    private static let inserts = (1...3).map { "INSERT INTO events VALUES (\($0))" }

    private static func server(failing: String? = nil, closingAfter: String? = nil) throws -> LibPQScriptedServer {
        try LibPQScriptedServer(
            status: { query, earlier in
                (earlier + [query]).contains("BEGIN") ? LibPQScriptedServer.inTransaction : LibPQScriptedServer.idle
            },
            answer: { query in
                guard query.hasPrefix("INSERT") else { return nil }
                if query == failing {
                    return .init(failure: .init(sqlState: "23505", message: "duplicate key value violates unique constraint"))
                }
                return .init(completion: "INSERT 0 1", closesSessionAtSync: query == closingAfter)
            }
        )
    }

    private static func connected(to server: LibPQScriptedServer) async throws -> LibPQPluginConnection {
        let connection = LibPQPluginConnection(
            host: "127.0.0.1", port: server.port, user: "postgres", password: nil, database: "postgres"
        )
        try await connection.connect()
        try await connection.finishConnecting()
        return connection
    }

    private static func driver(on server: LibPQScriptedServer) async throws -> PostgreSQLPluginDriver {
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: server.port, username: "postgres", password: "", database: "postgres"
        ))
        try await driver.connect()
        return driver
    }

    private static func statements(_ queries: [String]) -> [LibPQPipelineStatement] {
        queries.map { LibPQPipelineStatement(query: $0, parameters: []) }
    }

    private static func rowCounts(_ outcomes: [PluginBatchStatementOutcome]?) -> [Int?] {
        (outcomes ?? []).map {
            guard case .succeeded(let rowsAffected, _) = $0 else { return nil }
            return rowsAffected
        }
    }

    @Test("Inside a transaction block the statements go out as one pipeline and each reports its own count")
    func pipelinesInsideTransaction() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        _ = try await connection.executeQuery("BEGIN")

        let outcomes = try await connection.executePipeline(Self.statements(Self.inserts))

        #expect(Self.rowCounts(outcomes) == [1, 1, 1])
        #expect(server.parsedStatements == Self.inserts)
        #expect(await connection.transactionState() == .inTransaction)
        _ = try await connection.executeQuery("COMMIT")
        #expect(server.queries.last == "COMMIT")
    }

    @Test("A failure ends the run at that statement, and the server runs nothing after it")
    func failureStopsTheRun() async throws {
        let server = try Self.server(failing: Self.inserts[1])
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        _ = try await connection.executeQuery("BEGIN")

        let outcomes = try #require(try await connection.executePipeline(Self.statements(Self.inserts)))

        #expect(outcomes.count == 2)
        #expect(Self.rowCounts([outcomes[0]]) == [1])
        guard case .failed(let error) = outcomes[1] else {
            Issue.record("The second statement should have failed")
            return
        }
        #expect(error.localizedDescription.contains("duplicate key"))
        #expect(server.parsedStatements == Array(Self.inserts.prefix(2)))
        #expect(await connection.transactionState() == .inError)
        _ = try await connection.executeQuery("ROLLBACK")
    }

    @Test("A session lost after the last answer but before the Sync fails that last statement")
    func lostBeforeSyncFailsTheLastStatement() async throws {
        let server = try Self.server(closingAfter: Self.inserts[2])
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        _ = try await connection.executeQuery("BEGIN")

        let outcomes = try #require(try await connection.executePipeline(Self.statements(Self.inserts)))

        #expect(outcomes.count == 3)
        #expect(Self.rowCounts(Array(outcomes.prefix(2))) == [1, 1])
        guard case .failed = outcomes[2] else {
            Issue.record("The statement whose Sync never came should fail")
            return
        }
        #expect(connection.hasLostConnection)
    }

    @Test("Outside a transaction block the pipeline is declined and nothing is sent")
    func declinedOutsideTransaction() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        let sentBefore = server.queries

        let outcomes = try await connection.executePipeline(Self.statements(Self.inserts))

        #expect(outcomes == nil)
        #expect(server.queries == sentBefore)
    }

    @Test("Each statement binds its own parameters")
    func bindsParameters() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let connection = try await Self.connected(to: server)
        defer { connection.disconnect() }
        _ = try await connection.executeQuery("BEGIN")

        let outcomes = try await connection.executePipeline([
            LibPQPipelineStatement(query: "INSERT INTO events VALUES ($1)", parameters: [.text("a")]),
            LibPQPipelineStatement(query: "INSERT INTO events VALUES ($1, $2)", parameters: [.text("b"), .null]),
        ])

        #expect(Self.rowCounts(outcomes) == [1, 1])
        #expect(server.boundParameters.suffix(2) == [["a"], ["b", nil]])
    }

    @Test("The driver sends a statement a pipeline does not admit alone, and the stretches around it as pipelines")
    func driverSplitsAroundRefusedStatements() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let driver = try await Self.driver(on: server)
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "BEGIN")
        let queries = [Self.inserts[0], "SET search_path = app", Self.inserts[1], Self.inserts[2]]

        let outcomes = try await driver.executeStatements(queries.map {
            PluginBatchStatement(query: $0, parameters: nil, context: PluginStatementContext())
        })

        #expect(outcomes?.count == 4)
        #expect(server.parsedStatements.suffix(2) == Array(Self.inserts.suffix(2)))
        #expect(!server.parsedStatements.contains("SET search_path = app"))
        #expect(server.queries.contains("SET search_path = app"))
    }

    @Test("The driver declines a batch outside a transaction block or one holding a read-only statement")
    func driverDeclines() async throws {
        let server = try Self.server()
        defer { server.close() }
        server.start()
        let driver = try await Self.driver(on: server)
        defer { driver.disconnect() }
        let plain = Self.inserts.map { PluginBatchStatement(query: $0, parameters: nil, context: PluginStatementContext()) }

        #expect(try await driver.executeStatements(plain) == nil)

        _ = try await driver.execute(query: "BEGIN")
        var readOnly = PluginStatementContext()
        readOnly.enforcesReadOnly = true
        let withRead = plain + [PluginBatchStatement(query: "SELECT 1", parameters: nil, context: readOnly)]
        #expect(try await driver.executeStatements(withRead) == nil)
    }

    @Test("Only PostgreSQL itself declares statement batches")
    func capabilityIsPostgreSQLOnly() {
        let config = DriverConnectionConfig(host: "h", port: 5_432, username: "u", password: "", database: "d")
        #expect(PostgreSQLPluginDriver(config: config).capabilities.contains(.statementBatches))
        #expect(!PGlitePluginDriver(config: config).capabilities.contains(.statementBatches))
    }

    @Test("A statement's leading keyword is read past comments the way the server reads them", arguments: [
        ("insert into t values (1)", "INSERT"),
        ("  -- note\n/* a /* nested */ b */ Update t set a = 1", "UPDATE"),
        ("(SELECT 1)", nil),
        ("/* never closed", nil),
        ("", nil),
    ] as [(String, String?)])
    func leadingKeyword(text: String, keyword: String?) {
        #expect(LibPQPipelineAdmission.leadingKeyword(of: text) == keyword)
    }

    @Test("Transaction control, COPY and session settings are never pipelined", arguments: [
        "BEGIN", "commit", "ROLLBACK TO SAVEPOINT a", "SAVEPOINT a", "COPY t FROM STDIN", "SET search_path = a",
        "VACUUM t", "CALL p()", "DO $$ BEGIN END $$",
    ])
    func refusesSessionStatements(text: String) {
        #expect(!LibPQPipelineAdmission.admits(text))
    }

    @Test("A text that may hold a second statement goes alone, as a lone call sends it whole", arguments: [
        "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)", "INSERT INTO t VALUES ('a;b')", "DELETE FROM t; -- done",
    ])
    func refusesSeveralStatements(text: String) {
        #expect(!LibPQPipelineAdmission.admits(text))
    }

    @Test("Ordinary reads and writes are pipelined", arguments: [
        "INSERT INTO t VALUES (1);", "DELETE FROM t ;  \n",
        "INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t", "CREATE TABLE t (a int)",
        "SELECT pg_catalog.setval('s', 1, true)", "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x",
    ])
    func admitsOrdinaryStatements(text: String) {
        #expect(LibPQPipelineAdmission.admits(text))
    }

    @Test("A tally whose every statement answered but whose exchange broke fails the last statement")
    func tallyFailsLastWhenSyncIsLost() {
        var tally = LibPQPipelineTally(total: 2, startedAt: Date())
        tally.sent = 2
        for _ in 0..<2 {
            tally.take(.completed(rowsAffected: 1, commandTag: "INSERT 0 1"))
            _ = tally.endStatement()
        }
        struct Lost: Error {}

        let outcomes = tally.outcomes(cutShort: Lost())

        #expect(outcomes.count == 2)
        #expect(Self.rowCounts([outcomes[0]]) == [1])
        guard case .failed(let error) = outcomes[1] else {
            Issue.record("The last statement should carry the loss")
            return
        }
        #expect(error is Lost)
    }

    @Test("A tally stops at the first failure and names a cut-short statement only when one was never answered")
    func tallyOutcomes() {
        var tally = LibPQPipelineTally(total: 3, startedAt: Date())
        tally.sent = 3
        tally.take(.completed(rowsAffected: 2, commandTag: "UPDATE 2"))
        let firstEnded = tally.endStatement()
        tally.take(.aborted)
        let secondEnded = tally.endStatement()
        let strayEnded = tally.endStatement()
        struct Lost: Error {}

        let outcomes = tally.outcomes(cutShort: Lost())

        #expect(outcomes.count == 2)
        #expect(Self.rowCounts([outcomes[0]]) == [2])
        guard case .failed(let error) = outcomes[1] else {
            Issue.record("The aborted statement should report the cut")
            return
        }
        #expect(error is Lost)
        #expect(firstEnded && secondEnded)
        #expect(!strayEnded)
    }
}
