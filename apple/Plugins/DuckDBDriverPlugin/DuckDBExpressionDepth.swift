//
//  DuckDBExpressionDepth.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation

// DuckDB binds about 1 KiB of stack per level of an expression, also on threads of its own that get 512 KiB on macOS
// and iOS, where its default limit of 1,000 overflows them (core/docs/decisions/0031-duckdb-expression-depth.md).
nonisolated enum DuckDBExpressionDepth {
    static let configurationOption = "max_expression_depth"
    static let limit = "250"

    // DuckDB reads a file's expressions at open and ATTACH, prints them and writes them back with no limit of its
    // own, about 0.84 KiB a level: the stack its command line runs on, where a cooperative thread has 512 KiB.
    static let stackSize = 8 << 20

    static func open(
        _ path: String,
        config: duckdb_config?
    ) -> (state: duckdb_state, database: duckdb_database?, error: UnsafeMutablePointer<CChar>?) {
        nonisolated(unsafe) let config = config
        return onStack {
            var database: duckdb_database?
            var error: UnsafeMutablePointer<CChar>?
            let state = duckdb_open_ext(path, &database, config, &error)
            return (state: state, database: database, error: error)
        } ?? (state: DuckDBError, database: nil, error: nil)
    }

    static func close(_ database: inout duckdb_database?) {
        nonisolated(unsafe) let closing = database
        _ = onStack {
            var closed = closing
            duckdb_close(&closed)
        }
        database = nil
    }

    private static func onStack<Value>(_ body: @escaping @Sendable () -> Value) -> Value? {
        nonisolated(unsafe) var value: Value?
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            value = body()
            finished.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        finished.wait()
        return value
    }
}

// An actor's jobs, in order, on one thread of its own with DuckDB's stack.
nonisolated final class DuckDBStackExecutor: SerialExecutor, @unchecked Sendable {
    private let pending = DuckDBPendingJobs()

    init(name: String) {
        let pending = pending
        let thread = Thread { pending.run() }
        thread.name = name
        thread.stackSize = DuckDBExpressionDepth.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        pending.stop()
    }

    // The ExecutorJob form needs macOS 14 and the app runs on 13.
    func enqueue(_ job: UnownedJob) {
        pending.add(job, on: asUnownedSerialExecutor())
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

private nonisolated final class DuckDBPendingJobs: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [(job: UnownedJob, executor: UnownedSerialExecutor)] = []
    private var stopped = false

    func add(_ job: UnownedJob, on executor: UnownedSerialExecutor) {
        condition.lock()
        jobs.append((job: job, executor: executor))
        condition.signal()
        condition.unlock()
    }

    // The executor goes with its actor, which has no job left by then.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    func run() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopped {
                condition.wait()
            }
            guard !jobs.isEmpty else {
                condition.unlock()
                return
            }
            let next = jobs.removeFirst()
            condition.unlock()
            next.job.runSynchronously(on: next.executor)
        }
    }
}
