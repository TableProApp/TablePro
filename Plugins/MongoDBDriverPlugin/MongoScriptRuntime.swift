import Foundation
import JavaScriptCore
import TableProPluginKit
import os

/// What one statement of a script evaluated to.
struct MongoScriptStatementResult: Sendable {
    var documents = MongoScriptDocumentBatch.empty
    var collection: String?
    var scalarRows: [String]?
    var printedLines: [String] = []
    var databaseSwitch: String?
    var producedDocuments = false
    var rowsAffected = 0
}

/// Runs mongosh-shaped JavaScript against the connection.
///
/// One runtime per connection, which is what a shell is: `var`, functions and `use` survive from
/// one statement to the next exactly as they do in mongosh, and the app hands statements over one
/// at a time so each gets its own result. The context lives on a queue of its own because a
/// `JSContext` cannot suspend, so a host call has to block where it stands while the driver runs.
///
/// JavaScriptCore's public API has no way to interrupt a running script: the execution time limit
/// is private and absent from the SDK headers, measured. Cancellation therefore happens at host
/// call granularity, which covers every script that touches the database, and a script that spins
/// without one is abandoned along with its queue rather than left able to block the next run.
final class MongoScriptRuntime: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoScriptRuntime")

    /// How long a script may go without reaching the host before it is abandoned.
    static let silenceLimit: TimeInterval = 120
    private static let silenceCheckInterval: TimeInterval = 5

    private final class Engine {
        let queue: DispatchQueue
        let context: JSContext
        let host: MongoScriptHost
        var isPoisoned = false

        init(queue: DispatchQueue, context: JSContext, host: MongoScriptHost) {
            self.queue = queue
            self.context = context
            self.host = host
        }
    }

    private let connection: MongoDBConnection
    private let lock = NSLock()
    private var engine: Engine?
    private var generation = 0

    init(connection: MongoDBConnection) {
        self.connection = connection
    }

    // MARK: - Evaluation

    func evaluate(
        statement: String,
        database: String,
        valueCeiling: Int
    ) async throws -> MongoScriptStatementResult {
        let engine = try engine(startingAt: database, valueCeiling: valueCeiling)
        connection.beginScriptRun()

        let gate = MongoScriptResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
            // Captured strongly: a gate that is never finished leaves the caller waiting, and the
            // work is one statement long.
            engine.queue.async {
                gate.finish(with: Result { try self.run(statement, on: engine) })
            }
            watchForSilence(engine: engine, gate: gate)
        }
    }

    /// Gives up on a script that has stopped talking to the host.
    ///
    /// The deadline is measured from the last host call rather than from the start, so a script
    /// working through a large collection is never cut off: only one that is spinning without
    /// touching the database, printing or sleeping reaches it. There is no way to interrupt such a
    /// script through the public JavaScriptCore API, so its queue is abandoned and the next
    /// statement gets a new one.
    private func watchForSilence(engine: Engine, gate: MongoScriptResumeGate) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.silenceCheckInterval) {
            [weak self] in
            guard let self, !gate.isFinished else { return }
            guard Date().timeIntervalSince(engine.host.lastActivity) >= Self.silenceLimit else {
                watchForSilence(engine: engine, gate: gate)
                return
            }
            guard gate.finish(with: .failure(MongoDBError(
                code: 0, message: MongoScriptText.timedOut(Self.silenceLimit)
            ))) else { return }
            poison(engine)
        }
    }

    func cancel() {
        lock.lock()
        let running = engine
        lock.unlock()
        running?.host.markCancelled()
        connection.cancelCurrentQuery()
    }

    /// Drops the shell, so the next statement starts from a clean global scope.
    ///
    /// Only disconnecting does this. A database switch reassigns the global `db` instead and keeps
    /// everything the user has defined, which is what `use` does in mongosh; a collection already
    /// captured in a variable keeps pointing at the database it came from, there too.
    func reset() {
        lock.lock()
        let current = engine
        engine = nil
        lock.unlock()
        current?.queue.async { current?.host.reset(database: "", valueCeiling: 0) }
    }

    /// What an export should read, having evaluated the statement exactly once.
    ///
    /// `find()` and `aggregate()` build a lazy cursor and touch nothing, so the export can take the
    /// plan and page through the collection. Anything else has already run by the time we know
    /// that, and running it a second time would repeat a write, so its result is handed back
    /// instead of re-executed.
    func exportPlan(for statement: String, database: String) async throws -> MongoScriptExport {
        let engine = try engine(startingAt: database, valueCeiling: PluginRowLimits.emergencyMax)
        connection.beginScriptRun()
        return try await withCheckedThrowingContinuation { continuation in
            engine.queue.async {
                continuation.resume(with: Result { try self.runForExport(statement, on: engine) })
            }
        }
    }

    private func runForExport(_ statement: String, on engine: Engine) throws -> MongoScriptExport {
        engine.host.beginStatement()
        engine.context.exception = nil

        let value = engine.context.evaluateScript(statement)
        if let failure = engine.context.exception {
            engine.context.exception = nil
            if engine.host.isCancelled { throw CancellationError() }
            throw scriptError(failure, host: engine.host)
        }
        if engine.host.isCancelled { throw CancellationError() }

        if let value,
           let handle = value.objectForKeyedSubscript("__handle"), handle.isNumber,
           let plan = engine.host.cursorPlan(handle: Int(handle.toInt32())) {
            return .cursor(plan)
        }

        var result = MongoScriptStatementResult()
        result.printedLines = engine.host.printedLines
        result.databaseSwitch = engine.host.databaseSwitch
        if let value, !value.isUndefined {
            try classify(value, on: engine, into: &result)
        }
        return .result(result)
    }

    // MARK: - Engine

    /// The shell for this connection, built on first use and reused after that.
    ///
    /// The database is a starting point, not a per-statement input. Every scoped execution re-pins
    /// the driver to the tab's database, so re-deriving the shell's `db` here would undo a `use`
    /// the moment the next statement ran: the shell would report the switch and then query the old
    /// database. `rebindDatabase` is the only thing that moves it.
    ///
    /// Everything that touches the host or the `JSContext` runs on the engine's own queue, this
    /// included. Both are single-threaded by construction: the cursor registry is a plain
    /// dictionary and a `JSContext` may only be entered from one thread at a time, so preparing an
    /// engine from the caller's thread would race the statement running on it.
    private func engine(startingAt database: String, valueCeiling: Int) throws -> Engine {
        lock.lock()
        let existing = engine.flatMap { $0.isPoisoned ? nil : $0 }
        if existing == nil {
            generation += 1
        }
        let requestedGeneration = generation
        lock.unlock()

        if let existing {
            existing.queue.sync { existing.host.prepare(valueCeiling: valueCeiling) }
            return existing
        }

        let built = try makeEngine(
            database: database, valueCeiling: valueCeiling, generation: requestedGeneration
        )
        lock.lock()
        engine = built
        lock.unlock()
        return built
    }

    /// Moves the shell onto a database the user switched to in the app.
    ///
    /// Only an actual change reaches here, so the re-pinning every execution performs leaves a
    /// `use` alone.
    func rebindDatabase(_ database: String) {
        lock.lock()
        let current = engine.flatMap { $0.isPoisoned ? nil : $0 }
        lock.unlock()
        guard let current else { return }
        current.queue.sync {
            guard current.host.database != database else { return }
            current.host.reset(database: database, valueCeiling: current.host.valueCeiling)
            current.context.evaluateScript("db = new DB(\(MongoScriptJson.jsonString(database)));")
        }
    }

    private func makeEngine(database: String, valueCeiling: Int, generation: Int) throws -> Engine {
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            throw MongoDBError(code: 0, message: MongoScriptText.scriptEngineUnavailable)
        }
        let host = MongoScriptHost(
            connection: connection, database: database, valueCeiling: valueCeiling
        )
        let queue = DispatchQueue(
            label: "com.TablePro.mongodb.script.\(generation)", qos: .userInitiated
        )

        let execute: @convention(block) (String) -> String = { request in host.handle(request) }
        let emit: @convention(block) (String) -> Bool = { line in host.record(printed: line) }
        context.setObject(execute, forKeyedSubscript: "__tp_exec" as NSString)
        context.setObject(emit, forKeyedSubscript: "__tp_print" as NSString)
        context.exceptionHandler = { _, exception in
            Self.logger.debug("Script exception: \(exception?.toString() ?? "unknown", privacy: .public)")
        }

        context.evaluateScript(MongoScriptPrelude.source)
        if let failure = context.exception {
            throw MongoDBError(code: 0, message: failure.toString() ?? MongoScriptText.scriptEngineUnavailable)
        }
        return Engine(queue: queue, context: context, host: host)
    }

    /// Abandons an engine whose script stopped responding.
    ///
    /// The host is marked cancelled as well as detached. Without that, a script that computed
    /// silently past the deadline and *then* reached a host call would still perform its write,
    /// long after the caller had been told it timed out.
    private func poison(_ engine: Engine) {
        lock.lock()
        engine.isPoisoned = true
        if self.engine === engine { self.engine = nil }
        lock.unlock()
        engine.host.markCancelled()
        Self.logger.warning("Abandoned a MongoDB script that did not stop; its queue stays blocked")
    }

    // MARK: - One Statement

    private func run(_ statement: String, on engine: Engine) throws -> MongoScriptStatementResult {
        engine.host.beginStatement()
        engine.context.exception = nil

        let value = engine.context.evaluateScript(statement)
        if let failure = engine.context.exception {
            engine.context.exception = nil
            if engine.host.isCancelled { throw CancellationError() }
            throw scriptError(failure, host: engine.host)
        }
        if engine.host.isCancelled { throw CancellationError() }

        var result = MongoScriptStatementResult()
        result.printedLines = engine.host.printedLines
        result.databaseSwitch = engine.host.databaseSwitch

        guard let value, !value.isUndefined else { return result }
        try classify(value, on: engine, into: &result)
        return result
    }

    private func classify(
        _ value: JSValue,
        on engine: Engine,
        into result: inout MongoScriptStatementResult
    ) throws {
        guard let classifier = engine.context.objectForKeyedSubscript("__tp_classify"),
              let described = classifier.call(withArguments: [value])?.toString(),
              let data = described.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = payload["kind"] as? String else {
            return
        }

        if let failure = engine.context.exception {
            engine.context.exception = nil
            throw scriptError(failure, host: engine.host)
        }

        switch kind {
        case "cursor":
            guard let handle = payload["handle"] as? Int else { return }
            result.documents = try engine.host.drain(handle: handle)
            result.collection = engine.host.cursorDescription(handle: handle)?.collection
            result.producedDocuments = true
        case "array":
            guard let json = payload["json"] as? String else { return }
            let elements = MongoScriptJson.topLevelElements(json)
            if !elements.isEmpty, elements.allSatisfy({ $0.hasPrefix("{") }),
               !elements.contains(where: MongoScriptJson.isScalarWrapper) {
                result.documents = MongoScriptDocumentBatch(json: elements, isTruncated: false)
                result.producedDocuments = true
            } else {
                // `distinct` and friends answer with an array of plain values, which reads as one
                // row each rather than as one cell holding a JSON array.
                result.scalarRows = payload["texts"] as? [String] ?? []
            }
        case "document":
            guard let json = payload["json"] as? String else { return }
            result.documents = MongoScriptDocumentBatch(json: [json], isTruncated: false)
            result.producedDocuments = true
            result.rowsAffected = Self.rowsAffected(in: json)
        default:
            let text = (payload["text"] as? String) ?? (payload["json"] as? String)
            result.scalarRows = text.map { [$0] }
        }
    }

    /// How many documents a write reply says it changed.
    ///
    /// The shell answers a write with the object mongosh answers with, so the count the result bar
    /// reports has to be read back out of it rather than counted from the grid's one row.
    private static func rowsAffected(in json: String) -> Int {
        // Summed, not first-wins: a `bulkWrite` that mixes an insert with a delete carries two
        // positive counters and affected both rows.
        let total = ["modifiedCount", "deletedCount", "insertedCount", "upsertedCount"]
            .compactMap { MongoScriptJson.number(in: json, key: $0) }
            .filter { $0 > 0 }
            .reduce(0, +)
        if total > 0 { return Int(total) }
        return MongoScriptJson.member(of: json, key: "insertedId") == nil ? 0 : 1
    }

    private func scriptError(_ exception: JSValue, host: MongoScriptHost) -> Error {
        if exception.objectForKeyedSubscript("isMongoError")?.toBool() == true {
            let message = exception.objectForKeyedSubscript("message")?.toString() ?? ""
            if message == MongoScriptText.cancelled { return CancellationError() }
            let code = UInt32(max(0, exception.objectForKeyedSubscript("code")?.toInt32() ?? 0))
            return MongoDBError(code: code, message: message)
        }
        _ = host
        return MongoDBError(
            code: 0,
            message: exception.toString() ?? MongoScriptText.scriptEngineUnavailable
        )
    }
}

/// Resumes a continuation exactly once, whichever of the script and the deadline gets there first.
private final class MongoScriptResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MongoScriptStatementResult, Error>?
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func attach(_ continuation: CheckedContinuation<MongoScriptStatementResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func finish(with outcome: Result<MongoScriptStatementResult, Error>) -> Bool {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return false
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: outcome)
        return true
    }
}
