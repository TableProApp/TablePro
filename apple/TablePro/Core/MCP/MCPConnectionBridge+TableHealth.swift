import Foundation
import os
import TableProMCP

extension MCPConnectionBridge {
    // Reads the stored history and never records this run, so the tab's New and Resolved stay its own.
    func tableHealth(scope: DatabaseScope) async throws -> JsonValue {
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
        let report = try await TableHealthReportLoader.load(
            provider: provider,
            scope: DatabaseScope(connectionId: scope.connectionId, database: scope.database, schema: nil),
            metadata: DatabaseManager.shared
        )
        return Self.tableHealthPayload(report, ledger: ledger)
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
