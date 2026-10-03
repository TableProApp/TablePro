import CSQLite
import Foundation
import TableProPluginKit
import Testing

private struct LibSQLBusyTimeoutTestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class LibSQLLockedDatabase: @unchecked Sendable {
    private let url: URL
    private let locker: OpaquePointer
    private let waiter: OpaquePointer
    private let lock = NSLock()
    private var holdsExclusiveLock = false

    init(state: LibSQLBusyTimeoutState) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsql-busy-timeout-\(UUID().uuidString).sqlite")

        var locker: OpaquePointer?
        guard sqlite3_open(url.path, &locker) == SQLITE_OK, let locker else {
            throw LibSQLBusyTimeoutTestFailure(description: "Could not open the lock-owning SQLite connection")
        }
        self.locker = locker

        var waiter: OpaquePointer?
        guard sqlite3_open(url.path, &waiter) == SQLITE_OK, let waiter else {
            sqlite3_close(locker)
            try? FileManager.default.removeItem(at: url)
            throw LibSQLBusyTimeoutTestFailure(description: "Could not open the waiting SQLite connection")
        }
        self.waiter = waiter

        guard sqlite3_exec(locker, "CREATE TABLE item(value INTEGER)", nil, nil, nil) == SQLITE_OK else {
            throw LibSQLBusyTimeoutTestFailure(description: "Could not create the SQLite fixture table")
        }
        sqlite3_busy_handler(
            waiter,
            libSQLBusyTimeoutHandler,
            Unmanaged.passUnretained(state).toOpaque()
        )
    }

    deinit {
        releaseLock()
        sqlite3_close(waiter)
        sqlite3_close(locker)
        try? FileManager.default.removeItem(at: url)
    }

    func acquireLock() throws {
        guard sqlite3_exec(locker, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
            throw LibSQLBusyTimeoutTestFailure(description: "Could not acquire the SQLite fixture lock")
        }
        lock.withLock { holdsExclusiveLock = true }
    }

    func releaseLock() {
        let shouldRelease = lock.withLock {
            guard holdsExclusiveLock else { return false }
            holdsExclusiveLock = false
            return true
        }
        if shouldRelease {
            sqlite3_exec(locker, "ROLLBACK", nil, nil, nil)
        }
    }

    func insert() -> Int32 {
        sqlite3_exec(waiter, "INSERT INTO item VALUES (1)", nil, nil, nil)
    }
}

private struct LibSQLTestLocalDatabaseRuntime: LibSQLLocalDatabaseRuntime {
    func prepareDatabase(_: OpaquePointer, loading _: [LoadableExtension]) throws {}

    func stepFirst(_ statement: OpaquePointer?) -> LibSQLLocalFirstStep {
        let firstStep = SQLiteResultColumns.stepFirst(statement)
        return LibSQLLocalFirstStep(
            result: firstStep.result,
            names: firstStep.names,
            typeNames: firstStep.typeNames
        )
    }
}

private final class LibSQLBackendLockedDatabase: @unchecked Sendable {
    let path: String

    private let url: URL
    private let locker: OpaquePointer
    private let lock = NSLock()
    private var holdsWriteLock = false

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("libsql-backend-lock-\(UUID().uuidString).sqlite")
        path = url.path

        var locker: OpaquePointer?
        guard sqlite3_open(path, &locker) == SQLITE_OK, let locker else {
            throw LibSQLBusyTimeoutTestFailure(description: "Could not open the backend lock-owning connection")
        }
        self.locker = locker

        guard sqlite3_exec(locker, "CREATE TABLE item(value INTEGER)", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(locker)
            try? FileManager.default.removeItem(at: url)
            throw LibSQLBusyTimeoutTestFailure(description: "Could not create the backend fixture table")
        }
    }

    deinit {
        releaseLock()
        sqlite3_close(locker)
        try? FileManager.default.removeItem(at: url)
    }

    func acquireWriteLock() throws {
        guard sqlite3_exec(locker, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw LibSQLBusyTimeoutTestFailure(description: "Could not acquire the backend fixture lock")
        }
        lock.withLock { holdsWriteLock = true }
    }

    func releaseLock() {
        let shouldRelease = lock.withLock {
            guard holdsWriteLock else { return false }
            holdsWriteLock = false
            return true
        }
        if shouldRelease {
            sqlite3_exec(locker, "ROLLBACK", nil, nil, nil)
        }
    }
}

private enum LibSQLBackendOperationOutcome: Equatable, Sendable {
    case success
    case cancellation
    case failure(String)

    var isLockFailure: Bool {
        guard case .failure(let message) = self else { return false }
        let normalized = message.lowercased()
        if normalized.contains("locked") { return true }
        if normalized.contains("busy") { return true }
        return false
    }

    var wasCancelled: Bool {
        self == .cancellation
    }
}

@Suite("libSQL local busy timeout", .serialized)
struct LibSQLBusyTimeoutTests {
    @Test("No limit keeps retrying until the lock is released", .timeLimit(.minutes(1)))
    func noLimitWaitsForLockRelease() async throws {
        let state = LibSQLBusyTimeoutState()
        state.setTimeout(milliseconds: 0)
        let database = try LibSQLLockedDatabase(state: state)
        try database.acquireLock()

        let insert = Task.detached {
            state.beginOperation()
            return database.insert()
        }
        let sawRetry = await waitForRetry(state)
        database.releaseLock()

        let result = await boundedResult(of: insert, state: state, database: database)
        #expect(sawRetry)
        #expect(result == SQLITE_OK)
    }

    @Test("Cancellation ends an unlimited lock wait", .timeLimit(.minutes(1)))
    func cancellationEndsUnlimitedWait() async throws {
        let state = LibSQLBusyTimeoutState()
        state.setTimeout(milliseconds: 0)
        let database = try LibSQLLockedDatabase(state: state)
        try database.acquireLock()

        let insert = Task.detached {
            state.beginOperation()
            return database.insert()
        }
        let sawRetry = await waitForRetry(state)
        if sawRetry {
            state.cancel()
        } else {
            database.releaseLock()
        }

        let result = await boundedResult(of: insert, state: state, database: database)
        database.releaseLock()
        #expect(sawRetry)
        #expect(result == SQLITE_BUSY)
    }

    @Test("A positive timeout stops at its retry boundary")
    func positiveTimeoutHasFiniteBoundary() {
        let state = LibSQLBusyTimeoutState()
        state.setTimeout(milliseconds: 25)
        state.beginOperation()

        #expect(state.shouldRetry(afterRetryCount: 0))
        #expect(state.shouldRetry(afterRetryCount: 2))
        #expect(!state.shouldRetry(afterRetryCount: 3))
    }

    @Test("A finite timeout rejects a locked backend insert", .timeLimit(.minutes(1)))
    func finiteTimeoutRejectsLockedBackendInsert() async throws {
        try await withBackend { backend, database in
            await backend.applyBusyTimeout(25)
            try database.acquireWriteLock()

            let insert = Task {
                await Self.bufferedOutcome(backend, query: "INSERT INTO item VALUES (1)")
            }
            let outcome = await BoundedCall.result(
                within: .seconds(2),
                onDeadline: {
                    backend.cancelBusyWait()
                    database.releaseLock()
                },
                of: { await insert.value }
            )
            database.releaseLock()

            let completed = try #require(outcome)
            #expect(completed.isLockFailure)
            #expect(try await Self.rowCount(backend) == 0)
        }
    }

    @Test("Driver cancellation rejects a locked streaming insert", .timeLimit(.minutes(1)))
    func driverCancellationRejectsLockedStreamingInsert() async throws {
        try await withDriver { driver, database in
            try await driver.applyQueryTimeout(0)
            try database.acquireWriteLock()

            let insert = Task {
                await Self.streamingOutcome(driver, query: "INSERT INTO item VALUES (2) RETURNING value")
            }
            let sawRetry = await Self.waitForDriverRetry(driver)
            if sawRetry {
                try driver.cancelQuery()
            } else {
                database.releaseLock()
            }

            let outcome = await BoundedCall.result(
                within: .seconds(2),
                onDeadline: {
                    try? driver.cancelQuery()
                    database.releaseLock()
                },
                of: { await insert.value }
            )
            database.releaseLock()
            try await driver.applyQueryTimeout(1)

            #expect(sawRetry)
            let completed = try #require(outcome)
            #expect(completed.wasCancelled)
            #expect(try await Self.rowCount(driver) == 0)
        }
    }

    private func waitForRetry(_ state: LibSQLBusyTimeoutState) async -> Bool {
        for _ in 0 ..< 2_000 {
            if state.hasRetried { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func waitForDriverRetry(_ driver: LibSQLPluginDriver) async -> Bool {
        for _ in 0 ..< 2_000 {
            if driver.hasRetriedLocalBusyWait { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func boundedResult(
        of task: Task<Int32, Never>,
        state: LibSQLBusyTimeoutState,
        database: LibSQLLockedDatabase
    ) async -> Int32? {
        await BoundedCall.result(
            within: .seconds(2),
            onDeadline: {
                state.cancel()
                database.releaseLock()
            },
            of: { await task.value }
        )
    }

    private func withBackend(
        _ operation: (SQLiteLocalBackend, LibSQLBackendLockedDatabase) async throws -> Void
    ) async throws {
        let database = try LibSQLBackendLockedDatabase()
        let backend = SQLiteLocalBackend(runtime: LibSQLTestLocalDatabaseRuntime())
        try await backend.open(path: database.path, loading: [])
        do {
            try await operation(backend, database)
        } catch {
            await backend.close()
            throw error
        }
        await backend.close()
    }

    private func withDriver(
        _ operation: (LibSQLPluginDriver, LibSQLBackendLockedDatabase) async throws -> Void
    ) async throws {
        let database = try LibSQLBackendLockedDatabase()
        let config = DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: "",
            additionalFields: [
                "libsqlMode": "local",
                "libsqlFilePath": database.path
            ]
        )
        let driver = LibSQLPluginDriver(
            config: config,
            localDatabaseRuntime: LibSQLTestLocalDatabaseRuntime()
        )
        do {
            try await driver.connect()
            try await operation(driver, database)
        } catch {
            try? driver.cancelQuery()
            database.releaseLock()
            driver.disconnect()
            throw error
        }
        driver.disconnect()
    }

    private static func bufferedOutcome(
        _ backend: SQLiteLocalBackend,
        query: String
    ) async -> LibSQLBackendOperationOutcome {
        do {
            _ = try await backend.executeQuery(query)
            return .success
        } catch {
            return .failure(errorMessage(error))
        }
    }

    private static func streamingOutcome(
        _ driver: LibSQLPluginDriver,
        query: String
    ) async -> LibSQLBackendOperationOutcome {
        do {
            for try await _ in driver.streamRows(query: query) {}
            return .success
        } catch is CancellationError {
            return .cancellation
        } catch {
            return .failure(errorMessage(error))
        }
    }

    private static func rowCount(_ backend: SQLiteLocalBackend) async throws -> Int {
        let result = try await backend.executeQuery("SELECT COUNT(*) FROM item")
        return Int(result.rows.first?.first?.asText ?? "") ?? -1
    }

    private static func rowCount(_ driver: LibSQLPluginDriver) async throws -> Int {
        let result = try await driver.execute(query: "SELECT COUNT(*) FROM item")
        return Int(result.rows.first?.first?.asText ?? "") ?? -1
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? LibSQLError)?.message ?? String(describing: error)
    }
}
