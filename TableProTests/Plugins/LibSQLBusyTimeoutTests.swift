import CSQLite
import Foundation
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

    private func waitForRetry(_ state: LibSQLBusyTimeoutState) async -> Bool {
        for _ in 0 ..< 2_000 {
            if state.hasRetried { return true }
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
}
