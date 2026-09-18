import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import Testing

private enum WriteEvent: Equatable {
    case begin(PluginTransactionAccessMode)
    case beginWithoutMode
    case execute(String)
    case commit
    case rollback
}

private struct WriteFailure: Error, Equatable {}

private final class RecordingWriteDriver: DatabaseDriver, @unchecked Sendable {
    var supportsTransactions = true
    var scriptedState: DriverTransactionState = .idle
    var failingStatement: String?
    var failsBegin = false
    var rowsAffected: [String: Int] = [:]

    private(set) var events: [WriteEvent] = []

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() async throws {}
    func ping() async throws -> Bool { true }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        events.append(.execute(query))
        if query == failingStatement { throw WriteFailure() }
        return QueryResult(columns: [], rows: [], rowsAffected: rowsAffected[query] ?? 1, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    func switchSchema(to name: String) async throws {}
    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        events.append(.beginWithoutMode)
    }

    func beginTransaction(mode: PluginTransactionAccessMode) async throws {
        if failsBegin { throw WriteFailure() }
        events.append(.begin(mode))
    }

    func commitTransaction() async throws {
        events.append(.commit)
    }

    func rollbackTransaction() async throws {
        events.append(.rollback)
    }

    func sessionTransactionState() async -> DriverTransactionState { scriptedState }
}

private final class ProtocolDefaultDriver: DatabaseDriver, @unchecked Sendable {
    private(set) var events: [WriteEvent] = []

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() async throws {}
    func ping() async throws -> Bool { true }
    func cancelCurrentQuery() async throws {}

    func execute(query: String) async throws -> QueryResult {
        events.append(.execute(query))
        return QueryResult(columns: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func switchDatabase(to name: String) async throws {}
    func switchSchema(to name: String) async throws {}
    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        events.append(.beginWithoutMode)
    }

    func commitTransaction() async throws {
        events.append(.commit)
    }

    func rollbackTransaction() async throws {
        events.append(.rollback)
    }
}

@Suite("Write transaction policy")
struct WriteTransactionPolicyTests {
    @Test("A driver without transactions never opens one")
    func withoutTransactions() {
        for state in [DriverTransactionState.idle, .explicitTransaction, .implicitTransaction, .unknown] {
            for count in 1...2 {
                #expect(
                    WriteTransactionPolicy.opensTransaction(
                        supportsTransactions: false, state: state, statementCount: count
                    ) == false
                )
            }
        }
    }

    @Test("An idle session wraps whatever it is given")
    func idleWraps() {
        #expect(WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: .idle, statementCount: 1))
        #expect(WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: .idle, statementCount: 2))
    }

    @Test("A transaction the server opened because autocommit is off still wraps and commits")
    func implicitTransactionWraps() {
        #expect(
            WriteTransactionPolicy.opensTransaction(
                supportsTransactions: true, state: .implicitTransaction, statementCount: 1
            )
        )
        #expect(
            WriteTransactionPolicy.opensTransaction(
                supportsTransactions: true, state: .implicitTransaction, statementCount: 2
            )
        )
    }

    @Test("A transaction the user opened is joined, never wrapped")
    func explicitTransactionRunsBare() {
        #expect(
            WriteTransactionPolicy.opensTransaction(
                supportsTransactions: true, state: .explicitTransaction, statementCount: 1
            ) == false
        )
        #expect(
            WriteTransactionPolicy.opensTransaction(
                supportsTransactions: true, state: .explicitTransaction, statementCount: 2
            ) == false
        )
    }

    @Test("An unknown state wraps a batch for atomicity and leaves a single statement bare")
    func unknownFollowsStatementCount() {
        #expect(
            WriteTransactionPolicy.opensTransaction(
                supportsTransactions: true, state: .unknown, statementCount: 1
            ) == false
        )
        #expect(
            WriteTransactionPolicy.opensTransaction(supportsTransactions: true, state: .unknown, statementCount: 2)
        )
    }
}

@Suite("Driver write execution")
struct DatabaseDriverWriteTests {
    @Test("An idle session wraps a single statement in a read-write transaction")
    func idleSingleStatementWraps() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .idle

        let affected = try await driver.executeWrite(["UPDATE t SET v = 1"])

        #expect(affected == 1)
        #expect(driver.events == [.begin(.readWrite), .execute("UPDATE t SET v = 1"), .commit])
    }

    @Test("A session inside the user's transaction runs the statement bare")
    func explicitTransactionRunsBare() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .explicitTransaction

        _ = try await driver.executeWrite(["UPDATE t SET v = 1"])

        #expect(driver.events == [.execute("UPDATE t SET v = 1")])
    }

    @Test("A session with autocommit off is wrapped and committed")
    func implicitTransactionWraps() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .implicitTransaction

        _ = try await driver.executeWrite(["UPDATE t SET v = 1"])

        #expect(driver.events == [.begin(.readWrite), .execute("UPDATE t SET v = 1"), .commit])
    }

    @Test("An unknown state leaves a single statement bare and wraps a batch")
    func unknownStateFollowsStatementCount() async throws {
        let single = RecordingWriteDriver()
        single.scriptedState = .unknown
        _ = try await single.executeWrite(["UPDATE t SET v = 1"])
        #expect(single.events == [.execute("UPDATE t SET v = 1")])

        let batch = RecordingWriteDriver()
        batch.scriptedState = .unknown
        _ = try await batch.executeWrite(["INSERT a", "INSERT b"])
        #expect(batch.events == [.begin(.readWrite), .execute("INSERT a"), .execute("INSERT b"), .commit])
    }

    @Test("A driver without transactions runs a batch bare")
    func withoutTransactionsRunsBare() async throws {
        let driver = RecordingWriteDriver()
        driver.supportsTransactions = false
        driver.scriptedState = .idle

        _ = try await driver.executeWrite(["INSERT a", "INSERT b"])

        #expect(driver.events == [.execute("INSERT a"), .execute("INSERT b")])
    }

    @Test("A failed statement rolls back, rethrows and runs nothing after it")
    func failureRollsBack() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .idle
        driver.failingStatement = "INSERT b"

        await #expect(throws: WriteFailure.self) {
            _ = try await driver.executeWrite(["INSERT a", "INSERT b", "INSERT c"])
        }

        #expect(driver.events == [.begin(.readWrite), .execute("INSERT a"), .execute("INSERT b"), .rollback])
    }

    @Test("A begin that fails runs no statement and no rollback")
    func failedBeginStopsEverything() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .idle
        driver.failsBegin = true

        await #expect(throws: WriteFailure.self) {
            _ = try await driver.executeWrite(["INSERT a"])
        }

        #expect(driver.events.isEmpty)
    }

    @Test("The affected-row sum ignores a driver that reports a negative count")
    func negativeRowCountsAreIgnored() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .idle
        driver.rowsAffected = ["INSERT a": -1, "INSERT b": 3]

        let affected = try await driver.executeWrite(["INSERT a", "INSERT b"])

        #expect(affected == 3)
    }

    @Test("No statements means no transaction and no work")
    func emptyStatementsDoNothing() async throws {
        let driver = RecordingWriteDriver()
        driver.scriptedState = .idle

        let affected = try await driver.executeWrite([])

        #expect(affected == 0)
        #expect(driver.events.isEmpty)
    }

    @Test("A driver that implements neither requirement reports unknown and opens a plain transaction")
    func protocolDefaultsLeaveBehaviorUnchanged() async throws {
        let driver = ProtocolDefaultDriver()

        #expect(await driver.sessionTransactionState() == .unknown)

        _ = try await driver.executeWrite(["UPDATE t SET v = 1"])
        #expect(driver.events == [.execute("UPDATE t SET v = 1")])

        _ = try await driver.executeWrite(["INSERT a", "INSERT b"])
        #expect(
            driver.events == [
                .execute("UPDATE t SET v = 1"),
                .beginWithoutMode,
                .execute("INSERT a"),
                .execute("INSERT b"),
                .commit
            ]
        )
    }
}
