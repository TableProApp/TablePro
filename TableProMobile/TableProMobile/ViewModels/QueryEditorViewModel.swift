import Foundation
import os
import TableProDatabase
import TableProModels
import TableProQuery

@MainActor
@Observable
final class QueryEditorViewModel {
    nonisolated enum Phase: Sendable {
        case idle
        case running
        case finished
        case truncated(reason: TruncationReason)
        case error(AppError)
    }

    /// What the requests before an early end left behind. Each request commits as it runs, unless the script opened
    /// a transaction of its own, which then holds them.
    nonisolated enum StandingWork: Sendable, Equatable {
        case nothing
        case applied(count: Int)
        case openTransaction
        /// The session was in a transaction at some point, or cannot say, so whether earlier work stands is not known.
        case unknown
    }

    /// Where a run of several requests ended before its last one finished.
    nonisolated struct ScriptInterruption: Sendable, Equatable {
        nonisolated enum Cause: Sendable, Equatable {
            case failed(sql: String)
            case stopped
            case memoryPressure
        }

        let cause: Cause
        let position: Int
        let total: Int
        let kind: QueryScript.UnitKind
        let standingWork: StandingWork
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorViewModel")
    static let maxBufferedRows = 10_000
    private static let memorySafetyMarginBytes = 64 * 1_024 * 1_024
    private static let budgetCheckInterval = 500

    private let buffer: StreamingResultBuffer
    private(set) var phase: Phase = .idle
    private(set) var executionTime: TimeInterval = 0
    private(set) var requestCount = 0
    private(set) var currentRequest = 0
    private(set) var rowsAffectedTotal = 0
    private(set) var interruption: ScriptInterruption?

    @ObservationIgnored private var unitKind: QueryScript.UnitKind = .statement
    @ObservationIgnored private var runID: UInt64 = 0
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    init(windowCapacity: Int = QueryEditorViewModel.maxBufferedRows) {
        self.buffer = StreamingResultBuffer(capacity: windowCapacity)
    }

    var columns: [ColumnInfo] { buffer.columns }
    var window: RowWindow { buffer.window }
    var legacyRows: [[String?]] { buffer.legacyRows }
    var statusMessage: String? { buffer.statusMessage }
    var truncationReason: TruncationReason? { buffer.truncation }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// A run that ended, whatever it produced. A statement that changes no rows yields nothing at all, so the buffer
    /// alone cannot tell a finished run from one that never started.
    var hasOutcome: Bool {
        switch phase {
        case .idle, .running: false
        case .finished, .truncated, .error: true
        }
    }

    var truncationMessage: String? {
        guard let truncationReason else { return nil }
        let shown = buffer.legacyRows.count
        switch truncationReason {
        case .rowCap:
            return String(format: String(localized: "Showing the first %d rows. Add LIMIT to fetch more."), shown)
        case .memoryPressure:
            return String(format: String(localized: "Stopped at %d rows to stay within memory limits. Add LIMIT to fetch fewer."), shown)
        case .cancelled:
            return String(format: String(localized: "Stopped. Showing %d rows."), shown)
        case .driverLimit:
            return String(format: String(localized: "The database limited the result. Showing %d rows."), shown)
        }
    }

    var progressMessage: String {
        guard requestCount > 1 else { return String(localized: "Executing...") }
        switch unitKind {
        case .statement:
            return String(format: String(localized: "Running statement %1$d of %2$d"), currentRequest, requestCount)
        case .batch:
            return String(format: String(localized: "Running batch %1$d of %2$d"), currentRequest, requestCount)
        }
    }

    /// The result of a statement that returns no rows: what it changed, or that it ran.
    var commandMessage: String {
        if rowsAffectedTotal > 0 {
            return String(format: String(localized: "%d row(s) affected"), rowsAffectedTotal)
        }
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return String(localized: "Query executed successfully")
    }

    /// Only the last request's result is on screen, so a script that ran to the end says how many ran before it.
    var scriptSummary: String? {
        guard requestCount > 1, interruption == nil, QueryExecutionOutcome(phase: phase) == .completed else {
            return nil
        }
        switch unitKind {
        case .statement:
            return String(format: String(localized: "Ran %d statements"), requestCount)
        case .batch:
            return String(format: String(localized: "Ran %d batches"), requestCount)
        }
    }

    var interruptionHeadline: String? {
        guard let interruption else { return nil }
        switch (interruption.cause, interruption.kind) {
        case (.failed, .statement):
            return String(
                format: String(localized: "Statement %1$d/%2$d failed: %3$@"),
                interruption.position, interruption.total, errorMessage ?? ""
            )
        case (.failed, .batch):
            return String(
                format: String(localized: "Batch %1$d/%2$d failed: %3$@"),
                interruption.position, interruption.total, errorMessage ?? ""
            )
        case (.stopped, .statement):
            return String(
                format: String(localized: "Stopped at statement %1$d of %2$d."),
                interruption.position, interruption.total
            )
        case (.stopped, .batch):
            return String(
                format: String(localized: "Stopped at batch %1$d of %2$d."),
                interruption.position, interruption.total
            )
        case (.memoryPressure, .statement):
            return String(
                format: String(localized: "Stopped at statement %1$d of %2$d to stay within memory limits."),
                interruption.position, interruption.total
            )
        case (.memoryPressure, .batch):
            return String(
                format: String(localized: "Stopped at batch %1$d of %2$d to stay within memory limits."),
                interruption.position, interruption.total
            )
        }
    }

    var standingWorkNote: String? {
        guard let interruption else { return nil }
        let earlier: String?
        switch (interruption.standingWork, interruption.kind) {
        case (.openTransaction, _):
            return String(localized: "The transaction on this connection is still open. Commit or roll it back.")
        case (.unknown, _):
            return nil
        case (.nothing, _):
            earlier = nil
        case (.applied(let count), .statement):
            earlier = count == 1
                ? String(localized: "The statement before it stays applied.")
                : String(format: String(localized: "The %d statements before it stay applied."), count)
        case (.applied(let count), .batch):
            earlier = count == 1
                ? String(localized: "The batch before it stays applied.")
                : String(format: String(localized: "The %d batches before it stay applied."), count)
        }
        // SQL Server carries on past most errors inside a batch and does not say which statements it reached.
        guard interruption.kind == .batch, case .failed = interruption.cause else { return earlier }
        let withinBatch = String(localized: "Any statement in the batch that ran stays applied.")
        return earlier.map { "\($0) \(withinBatch)" } ?? withinBatch
    }

    var failedSQL: String? {
        guard case .failed(let sql) = interruption?.cause else { return nil }
        return sql
    }

    /// The line history keeps for a run that ended early, so a script's row says which request it ended at.
    var interruptionSummary: String? {
        guard let interruptionHeadline else { return nil }
        guard let standingWorkNote else { return interruptionHeadline }
        return "\(interruptionHeadline) \(standingWorkNote)"
    }

    private var errorMessage: String? {
        guard case .error(let error) = phase else { return nil }
        return error.message
    }

    func run(driver: DatabaseDriver, script: QueryScript, maxRows: Int = QueryEditorViewModel.maxBufferedRows) async {
        fetchTask?.cancel()
        let options = StreamOptions(
            textTruncationBytes: 4_096,
            inlineBinary: false,
            maxRows: maxRows,
            lazyContext: nil
        )
        runID &+= 1
        let run = runID
        phase = .running
        buffer.reset()
        executionTime = 0
        rowsAffectedTotal = 0
        interruption = nil
        unitKind = script.unitKind
        requestCount = script.requestCount
        currentRequest = 0
        startedAt = Date()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRequests(of: script, run: run, driver: driver, options: options)
        }
        fetchTask = task
        await task.value
    }

    func stop() {
        guard case .running = phase else { return }
        buffer.markTruncated(.cancelled)
        fetchTask?.cancel()
    }

    func reset() {
        runID &+= 1
        fetchTask?.cancel()
        buffer.reset()
        executionTime = 0
        rowsAffectedTotal = 0
        interruption = nil
        requestCount = 0
        currentRequest = 0
        phase = .idle
    }

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                return
            case .warning, .critical:
                guard case .running = self.phase else { return }
                Self.logger.warning("Memory pressure: stopping query stream to stay within limits")
                self.buffer.markTruncated(.memoryPressure)
                self.fetchTask?.cancel()
                self.phase = .truncated(reason: .memoryPressure)
            }
        }
    }

    /// Runs each request only after the one before it has finished, and none after Stop, a failure or memory
    /// pressure. A driver's interrupt reaches only a statement that is running, so the check before each request is
    /// what keeps a stopped script from going on.
    ///
    /// The session's transaction state is read after each request finishes, while the connection is idle: a stopped
    /// request may still hold the driver, and reading it then would wait for the statement Stop is meant to end.
    private func runRequests(of initial: QueryScript, run: UInt64, driver: DatabaseDriver, options: StreamOptions) async {
        var script = initial
        var index = 0
        var position = 0
        var observedStates: [DriverTransactionState] = []
        while script.units.indices.contains(index) {
            let unit = script.units[index]
            for _ in 0..<max(unit.repeatCount, 1) {
                guard isRunning, !Task.isCancelled else {
                    settleStopped(atRequest: position + 1, run: run, observedStates: observedStates)
                    return
                }
                position += 1
                currentRequest = position
                if position > 1 {
                    buffer.reset()
                }
                do {
                    guard try await stream(unit.sql, driver: driver, options: options) else {
                        settleStopped(atRequest: position, run: run, observedStates: observedStates)
                        return
                    }
                    rowsAffectedTotal += buffer.rowsAffected ?? 0
                } catch is CancellationError {
                    settleStopped(atRequest: position, run: run, observedStates: observedStates)
                    return
                } catch where Task.isCancelled || !isRunning {
                    // Stop interrupts the statement, and the driver may answer with its interrupt error.
                    settleStopped(atRequest: position, run: run, observedStates: observedStates)
                    return
                } catch {
                    let stateAfterFailure = requestCount > 1 ? await driver.sessionTransactionState() : .unknown
                    settleFailed(
                        error,
                        sql: unit.sql,
                        atRequest: position,
                        run: run,
                        standingWork: Self.standingWork(
                            before: position, observedStates: observedStates, now: stateAfterFailure
                        )
                    )
                    return
                }
                if requestCount > 1 {
                    observedStates.append(await driver.sessionTransactionState())
                }
            }
            if script.units.indices.contains(index + 1),
               let rest = await replannedIfSessionChanged(script, after: index, driver: driver) {
                script = rest
                index = 0
                requestCount = position + rest.requestCount
                continue
            }
            index += 1
        }
        guard run == runID else { return }
        buffer.flush()
        finalizeTiming()
        resolvePhase()
    }

    /// A statement such as `SET sql_mode = 'NO_BACKSLASH_ESCAPES'` changes how the server reads every literal after
    /// it, so the rest of the text is split again by what the session now says.
    private func replannedIfSessionChanged(
        _ script: QueryScript,
        after index: Int,
        driver: DatabaseDriver
    ) async -> QueryScript? {
        guard script.unitKind == .statement else { return nil }
        let facts = await driver.sessionLexicalFacts()
        guard facts != script.session else { return nil }
        return script.replanned(after: index, session: facts)
    }

    /// False when the request was cut short: by Stop, by memory pressure, or by another query that took over the
    /// connection, whose driver then ends this stream as cancelled.
    private func stream(_ sql: String, driver: DatabaseDriver, options: StreamOptions) async throws -> Bool {
        var sinceBudgetCheck = 0
        for try await element in driver.executeStreaming(query: sql, options: options) {
            if Task.isCancelled { return false }
            buffer.apply(element)
            guard case .row = element else { continue }
            sinceBudgetCheck += 1
            if sinceBudgetCheck >= Self.budgetCheckInterval {
                sinceBudgetCheck = 0
                if isMemoryConstrained() {
                    buffer.markTruncated(.memoryPressure)
                    return false
                }
            }
        }
        if case .cancelled? = buffer.truncation { return false }
        return !Task.isCancelled
    }

    /// A run that Clear or a newer run replaced settles nothing, so its late end cannot overwrite what replaced it.
    private func settleStopped(atRequest position: Int, run: UInt64, observedStates: [DriverTransactionState]) {
        guard run == runID else { return }
        buffer.flush()
        finalizeTiming()
        let reason = buffer.truncation ?? .cancelled
        if requestCount > 1 {
            let cause: ScriptInterruption.Cause
            if case .memoryPressure = reason {
                cause = .memoryPressure
            } else {
                cause = .stopped
            }
            interruption = ScriptInterruption(
                cause: cause,
                position: min(position, requestCount),
                total: requestCount,
                kind: unitKind,
                standingWork: Self.standingWork(
                    before: position, observedStates: observedStates, now: observedStates.last ?? .unknown
                )
            )
        }
        phase = .truncated(reason: reason)
    }

    private func settleFailed(
        _ error: Error,
        sql: String,
        atRequest position: Int,
        run: UInt64,
        standingWork: StandingWork
    ) {
        guard run == runID else { return }
        buffer.flush()
        finalizeTiming()
        if requestCount > 1 {
            interruption = ScriptInterruption(
                cause: .failed(sql: sql),
                position: position,
                total: requestCount,
                kind: unitKind,
                standingWork: standingWork
            )
        }
        phase = .error(classify(error: error))
    }

    /// Earlier requests stand only when the session was seen outside a transaction after every one of them: a
    /// script's own `BEGIN` and `ROLLBACK` leaves an idle session with nothing kept, and an engine that cannot say
    /// leaves nothing certain.
    private static func standingWork(
        before position: Int,
        observedStates: [DriverTransactionState],
        now: DriverTransactionState
    ) -> StandingWork {
        if now == .explicitTransaction || now == .implicitTransaction { return .openTransaction }
        guard now == .idle, observedStates.allSatisfy({ $0 == .idle }) else { return .unknown }
        return position > 1 ? .applied(count: position - 1) : .nothing
    }

    private func isMemoryConstrained() -> Bool {
        !MemoryPressureMonitor.shared.hasHeadroom(forBytes: Self.memorySafetyMarginBytes)
    }

    private func resolvePhase() {
        if let reason = buffer.truncation {
            phase = .truncated(reason: reason)
        } else if case .running = phase {
            phase = .finished
        }
    }

    private func finalizeTiming() {
        if let startedAt {
            executionTime = Date().timeIntervalSince(startedAt)
        }
    }

    private func classify(error: Error) -> AppError {
        let context = ErrorContext(operation: "executeQuery")
        return ErrorClassifier.classify(error, context: context)
    }
}
