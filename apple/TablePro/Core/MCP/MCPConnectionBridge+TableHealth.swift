import Foundation
import os
import TableProMCP

extension MCPConnectionBridge {
    // Reads the stored history and never records this run, so the tab's New and Resolved stay its own.
    func tableHealth(scope: DatabaseScope, timeoutSeconds: Int) async throws -> JsonValue {
        let databaseType = try await ensureConnected(scope.connectionId)
        guard let provider = TableHealthProviderFactory.provider(for: databaseType) else {
            throw MCPToolExecutionError.unsupported(
                String(localized: "TablePro has no Table Health checks for this engine.")
            )
        }
        guard !scope.isServerScoped else {
            throw DatabaseAccessError.invalidArgument(
                String(localized: "The connection has no current database. Pass a database name.")
            )
        }
        let ledger = try await Self.tableHealthLedger(connectionId: scope.connectionId, database: scope.database)
        // The checks cover every schema, as the Table Health tab does.
        let reportScope = DatabaseScope(connectionId: scope.connectionId, database: scope.database, schema: nil)
        let report = try await Self.withinTableHealthTimeout(seconds: timeoutSeconds) {
            try await TableHealthReportLoader.load(provider: provider, scope: reportScope, metadata: DatabaseManager.shared)
        }
        return Self.tableHealthPayload(report, ledger: ledger)
    }

    // Answers at the deadline and lets the checks wind down after it: a read queued on the pool's serial lane sees its
    // cancel only when the job ahead of it ends, and a catalog read already running cannot be stopped on the server.
    static func withinTableHealthTimeout<T: Sendable>(
        seconds: Int,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let deadline = TableHealthDeadline<T>()
        let work = Task {
            do {
                deadline.settle(.success(try await body()))
            } catch {
                deadline.settle(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            deadline.settle(.failure(DatabaseAccessError.timeout(
                String(
                    format: String(localized: "Table Health did not finish within the MCP query timeout of %lld seconds."),
                    seconds
                )
            )))
            work.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await deadline.wait()
        } onCancel: {
            deadline.settle(.failure(CancellationError()))
            work.cancel()
        }
    }

    private static func tableHealthLedger(connectionId: UUID, database: String) async throws -> TableHealthLedger {
        do {
            return try await MainActor.run {
                try TableHealthHistoryStorage.shared.ledger(connectionId: connectionId, database: database)
            }
        } catch {
            logger.error("Table Health history unreadable for MCP: \(error.publicLogShape, privacy: .public)")
            throw MCPToolExecutionError(
                code: .internalFailure,
                message: String(localized: "TablePro could not read its Table Health history for this connection.")
            )
        }
    }

    static func tableHealthPayload(_ report: TableHealthReport, ledger: TableHealthLedger) -> JsonValue {
        .object([
            "database": .string(report.database),
            "generated_at": .string(iso8601.withLockUnchecked { $0.string(from: report.generatedAt) }),
            "notes": .array(report.notes.map { .string($0) }),
            "checks": .array(report.checks.map(tableHealthCheckPayload)),
            "findings": .array(report.findings.map { finding in
                tableHealthFindingPayload(finding, status: ledger.mcpStatus(of: finding.id))
            })
        ])
    }

    static func tableHealthCheckPayload(_ result: TableHealthCheckResult) -> JsonValue {
        var fields: [String: JsonValue] = [
            "kind": .string(result.kind.rawValue),
            "title": .string(result.check.title),
            "summary": .string(result.check.summary),
            "finding_count": .int(result.findings.count)
        ]
        switch result.outcome {
        case .completed:
            fields["outcome"] = .string("completed")
        case .skipped(let reason):
            fields["outcome"] = .string("skipped")
            fields["reason"] = .string(reason)
        case .failed(let message):
            fields["outcome"] = .string("failed")
            fields["reason"] = .string(tableHealthCheckFailure(kind: result.kind, message: message))
        }
        if let note = result.note {
            fields["note"] = .string(note)
        }
        return .object(fields)
    }

    // The client is told which check failed, never what the server said: its text can name a role, a table or a
    // statement, and this reply leaves the Mac. The Table Health tab shows the full message.
    static func tableHealthCheckFailure(kind: TableHealthCheckKind, message: String) -> String {
        logger.warning(
            "Table Health check \(kind.rawValue, privacy: .public) failed: \(message, privacy: .private)"
        )
        return String(localized: "The server did not answer this check.")
    }

    static func tableHealthFindingPayload(_ finding: TableHealthFinding, status: TableHealthFindingStatus) -> JsonValue {
        var fields: [String: JsonValue] = [
            "kind": .string(finding.kind.rawValue),
            "detail": .string(finding.detail),
            "metrics": .array(finding.metrics.map(tableHealthMetricPayload)),
            "status": .string(status.rawValue)
        ]
        if let schema = finding.schema {
            fields["schema"] = .string(schema)
        }
        if let table = finding.table {
            fields["table"] = .string(table)
        }
        if let object = finding.objectName {
            fields["object"] = .string(object)
        }
        if let sizeBytes = finding.sizeBytes {
            fields["size_bytes"] = .int(Int(sizeBytes))
        }
        if let fixSQL = finding.fixSQL {
            fields["fix_sql"] = .string(fixSQL)
        }
        return .object(fields)
    }

    static func tableHealthMetricPayload(_ metric: TableHealthMetric) -> JsonValue {
        let type: String
        let value: JsonValue
        switch metric.value {
        case .count(let count):
            type = "count"
            value = .int(Int(count))
        case .bigCount(let count):
            type = "count"
            // JSON numbers past Int64 lose digits in most clients, so the largest unsigned counters go as text.
            value = count <= UInt64(Int.max) ? .int(Int(count)) : .string(String(count))
        case .bytes(let bytes):
            type = "bytes"
            value = .int(Int(bytes))
        case .percent(let fraction):
            type = "percent"
            value = fraction.isFinite ? .double(fraction) : .null
        case .date(let date):
            type = "date"
            value = .string(iso8601.withLockUnchecked { $0.string(from: date) })
        case .text(let text):
            type = "text"
            value = .string(text)
        case .flag(let flag):
            type = "flag"
            value = .bool(flag)
        }
        return .object([
            "id": .string(metric.id),
            "label": .string(metric.label),
            "type": .string(type),
            "value": value
        ])
    }
}

// The first outcome wins; later ones are dropped, so a read that ends after the timeout answered changes nothing.
private final class TableHealthDeadline<T: Sendable>: Sendable {
    private enum State: Sendable {
        case running
        case waiting(CheckedContinuation<T, any Error>)
        case settled(Result<T, any Error>)
        case delivered
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .running)

    func settle(_ result: Result<T, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<T, any Error>? in
            switch state {
            case .running:
                state = .settled(result)
                return nil
            case .waiting(let continuation):
                state = .delivered
                return continuation
            case .settled, .delivered:
                return nil
            }
        }
        waiter?.resume(with: result)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<T, any Error>? in
                switch state {
                case .running:
                    state = .waiting(continuation)
                    return nil
                case .settled(let result):
                    state = .delivered
                    return result
                case .waiting, .delivered:
                    return .failure(CancellationError())
                }
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }
}
