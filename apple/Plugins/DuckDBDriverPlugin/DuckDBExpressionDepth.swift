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

    static func onStack<Value>(_ body: @escaping @Sendable () -> Value) -> Value? {
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

// DuckDB runs a statement's tasks on the caller and on threads of its own, which get 512 KiB on macOS and iOS, and an
// ATTACH or read_duckdb() reads the other file's expressions inside one. With external_threads at the thread count
// DuckDB starts none, and these run its tasks with its command line's stack instead.
nonisolated final class DuckDBTaskThreads {
    // DuckDB's own default, std::thread::hardware_concurrency().
    static let count = max(ProcessInfo.processInfo.processorCount, 1)
    static let openOptions: [(name: String, value: String)] = [
        (name: "threads", value: String(count)),
        (name: "external_threads", value: String(count)),
    ]
    // A statement that raises the count and locks the configuration, as IMPORT DATABASE can, still lets these take
    // DuckDB's threads over.
    static let sessionOptions = openOptions + [(name: "allowed_configs", value: "[external_threads]")]

    private let database: duckdb_database
    // Its own, so a cancel or an aborted transaction on a session cannot stop a change of the count halfway.
    private var connection: duckdb_connection?
    private var state: duckdb_task_state?
    private var workers = 0
    // threads and external_threads as these last set them; nil once DuckDB keeps threads of its own.
    private var pinned: Int? = DuckDBTaskThreads.count
    private let running = DispatchGroup()

    // Without its connection it starts no thread, and every task runs on the caller's.
    init(database: duckdb_database) {
        self.database = database
        guard duckdb_connect(database, &connection) != DuckDBError else {
            connection = nil
            return
        }
        start(Self.count - 1)
    }

    // Before duckdb_close: a connection left open keeps the file.
    func close() {
        stop()
        if connection != nil {
            duckdb_disconnect(&connection)
        }
    }

    // DuckDB refuses a count below external_threads. One above it makes DuckDB start threads of its own, which these
    // take over before anything else runs: a later change ends them with one wake-up each through the semaphore these
    // wait on too, and a wake-up one of these took leaves DuckDB's join waiting for good (measured).
    func followCount() {
        guard !pinnedStillHolds() else { return }
        retake()
    }

    static func keepsCount(_ type: duckdb_statement_type) -> Bool {
        switch type {
        case DUCKDB_STATEMENT_TYPE_SELECT, DUCKDB_STATEMENT_TYPE_INSERT, DUCKDB_STATEMENT_TYPE_UPDATE,
             DUCKDB_STATEMENT_TYPE_DELETE, DUCKDB_STATEMENT_TYPE_TRANSACTION:
            return true
        default:
            return false
        }
    }

    private func pinnedStillHolds() -> Bool {
        guard let pinned, let connection, let counts = Self.counts(on: connection) else { return false }
        return counts.threads == pinned && counts.external == pinned
    }

    private func retake() {
        stop()
        pinned = nil
        guard let connection, let threads = Self.counts(on: connection)?.threads,
              Self.run("SET external_threads = \(threads)", on: connection) else { return }
        pinned = threads
        start(threads - 1)
    }

    private func stop() {
        guard let state else { return }
        // A thread DuckDB started itself, after a statement raised the count, can take the wake-up meant for one of these.
        repeat {
            duckdb_finish_execution(state)
        } while running.wait(timeout: .now() + .milliseconds(10)) == .timedOut
        duckdb_destroy_task_state(state)
        self.state = nil
        workers = 0
    }

    private func start(_ count: Int) {
        guard count > 0, let state = duckdb_create_task_state(database) else { return }
        self.state = state
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, DuckDBExpressionDepth.stackSize)
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED)
        pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED, 0)
        for _ in 0..<count {
            let worker = Unmanaged.passRetained(DuckDBTaskWorker(state: state, running: running)).toOpaque()
            running.enter()
            var thread: pthread_t?
            let created = pthread_create(&thread, &attributes, { context in
                let worker = Unmanaged<DuckDBTaskWorker>.fromOpaque(context).takeRetainedValue()
                pthread_setname_np("com.TablePro.duckdb.task")
                duckdb_execute_tasks_state(worker.state)
                worker.running.leave()
                return nil
            }, worker)
            // DuckDB stops starting threads at the system's limit the same way.
            guard created == 0 else {
                Unmanaged<DuckDBTaskWorker>.fromOpaque(worker).release()
                running.leave()
                break
            }
            workers += 1
        }
    }

    private static func run(_ sql: String, on connection: duckdb_connection) -> Bool {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        return duckdb_query(connection, sql, &result) != DuckDBError
    }

    private static func counts(on connection: duckdb_connection) -> (threads: Int, external: Int)? {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        let sql = "SELECT current_setting('threads')::BIGINT, current_setting('external_threads')::BIGINT"
        guard duckdb_query(connection, sql, &result) != DuckDBError else { return nil }
        var chunk = duckdb_fetch_chunk(result)
        guard chunk != nil else { return nil }
        defer { duckdb_destroy_data_chunk(&chunk) }
        guard duckdb_data_chunk_get_size(chunk) == 1,
              let threads = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 0)),
              let external = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 1))
        else { return nil }
        let counts = (
            threads: Int(threads.assumingMemoryBound(to: Int64.self).pointee),
            external: Int(external.assumingMemoryBound(to: Int64.self).pointee)
        )
        return counts.threads > 0 ? counts : nil
    }
}

private nonisolated final class DuckDBTaskWorker: @unchecked Sendable {
    let state: duckdb_task_state
    let running: DispatchGroup

    init(state: duckdb_task_state, running: DispatchGroup) {
        self.state = state
        self.running = running
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
