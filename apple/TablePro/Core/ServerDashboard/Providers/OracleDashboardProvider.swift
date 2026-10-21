//
//  OracleDashboardProvider.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Dynamic performance views are named `SYS.V_$...`, because the `V$` public synonyms resolve after
/// an object of the same name in the session's current schema.
struct OracleDashboardProvider: ServerDashboardQueryProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "OracleDashboardProvider")

    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    /// `ALTER SYSTEM CANCEL SQL` arrived in 18c.
    let hasCancelSQL: Bool

    init(serverVersion: String?) {
        hasCancelSQL = Self.release(from: serverVersion).map { $0 >= 18 } ?? true
    }

    /// 23.26 calls itself "Oracle AI Database 26ai Free Release 23.26.3.0.0": the release number is
    /// the one after `Release`, not the marketing name.
    static func release(from banner: String?) -> Int? {
        guard let banner, let range = banner.range(of: "Release ") else { return nil }
        let digits = banner[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    static let sessionsQuery = """
        SELECT s.SID || ',' || s.SERIAL# AS SESSION_ID, s.USERNAME, s.SCHEMANAME, s.STATUS, s.LAST_CALL_ET,
               NVL(
                   (SELECT q.SQL_TEXT FROM SYS.V_$SQL q
                    WHERE q.SQL_ID = s.SQL_ID AND q.CHILD_NUMBER = s.SQL_CHILD_NUMBER AND ROWNUM = 1),
                   (SELECT q.SQL_TEXT FROM SYS.V_$SQL q
                    WHERE q.SQL_ID = s.PREV_SQL_ID AND q.CHILD_NUMBER = s.PREV_CHILD_NUMBER AND ROWNUM = 1)
               ) AS SQL_TEXT
        FROM SYS.V_$SESSION s
        WHERE s.TYPE = 'USER' AND s.SID <> SYS_CONTEXT('USERENV', 'SID')
        ORDER BY s.LAST_CALL_ET DESC
        """

    static let slowQueriesQuery = """
        SELECT s.LAST_CALL_ET, s.USERNAME, s.SCHEMANAME,
               (SELECT q.SQL_TEXT FROM SYS.V_$SQL q
                WHERE q.SQL_ID = s.SQL_ID AND q.CHILD_NUMBER = s.SQL_CHILD_NUMBER AND ROWNUM = 1) AS SQL_TEXT
        FROM SYS.V_$SESSION s
        WHERE s.TYPE = 'USER' AND s.STATUS = 'ACTIVE' AND s.LAST_CALL_ET >= 1
          AND s.SID <> SYS_CONTEXT('USERENV', 'SID')
        ORDER BY s.LAST_CALL_ET DESC
        """

    static let sessionCountQuery = "SELECT COUNT(*) FROM SYS.V_$SESSION WHERE TYPE = 'USER'"

    static let uptimeQuery = "SELECT FLOOR((SYSDATE - STARTUP_TIME) * 86400) FROM SYS.V_$INSTANCE"

    static let rateMetricNames = ["CPU Usage Per Sec", "Logical Reads Per Sec"]

    /// The instance-wide view holds a row per metric in the root container and in a non-CDB, and none
    /// in a pluggable database, which reports its own figures in `V$CON_SYSMETRIC` (12.2 and later).
    static let rateQueries: [String] = {
        let names = rateMetricNames.map { "'\($0)'" }.joined(separator: ", ")
        let select = "SELECT METRIC_NAME, TO_CHAR(ROUND(VALUE, 1), 'FM999999999990.0') AS VALUE"
        return [
            "\(select) FROM SYS.V_$SYSMETRIC WHERE GROUP_ID = 2 AND METRIC_NAME IN (\(names))",
            "\(select) FROM SYS.V_$CON_SYSMETRIC WHERE METRIC_NAME IN (\(names))",
        ]
    }()

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let result = try await execute(Self.sessionsQuery)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["last_call_et"])) ?? 0
            return DashboardSession(
                id: value(row, at: col["session_id"]),
                user: value(row, at: col["username"]),
                database: value(row, at: col["schemaname"]),
                state: value(row, at: col["status"]),
                durationSeconds: secs,
                duration: DurationFormatting.string(seconds: secs),
                query: value(row, at: col["sql_text"])
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []
        var firstFailure: Error?

        func attempt(_ id: String, _ body: () async throws -> Void) async throws {
            do {
                try await body()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.warning("Metric \(id, privacy: .public) failed: \(error.publicLogShape, privacy: .public)")
                if firstFailure == nil { firstFailure = error }
            }
        }

        try await attempt("sessions") {
            let result = try await execute(Self.sessionCountQuery)
            guard let row = result.rows.first else { return }
            metrics.append(DashboardMetric(
                id: "sessions",
                label: String(localized: "User Sessions"),
                value: value(row, at: 0),
                unit: "",
                icon: "person.2"
            ))
        }

        try await attempt("rates") {
            let rates = try await rateValues(execute: execute)
            if let cpu = rates["CPU Usage Per Sec"] {
                metrics.append(DashboardMetric(
                    id: "cpu",
                    label: String(localized: "Database CPU"),
                    value: cpu,
                    unit: "%",
                    icon: "cpu"
                ))
            }
            if let reads = rates["Logical Reads Per Sec"] {
                metrics.append(DashboardMetric(
                    id: "logical_reads",
                    label: String(localized: "Logical Reads"),
                    value: reads,
                    unit: String(localized: "per second"),
                    icon: "doc.text.magnifyingglass"
                ))
            }
        }

        try await attempt("uptime") {
            let result = try await execute(Self.uptimeQuery)
            guard let row = result.rows.first, let secs = Int(value(row, at: 0)) else { return }
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: DurationFormatting.string(seconds: secs),
                unit: "",
                icon: "clock"
            ))
        }

        if metrics.isEmpty, let firstFailure {
            throw firstFailure
        }
        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let result = try await execute(Self.slowQueriesQuery)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = Int(value(row, at: col["last_call_et"])) ?? 0
            return DashboardSlowQuery(
                duration: DurationFormatting.string(seconds: secs),
                query: value(row, at: col["sql_text"]),
                user: value(row, at: col["username"]),
                database: value(row, at: col["schemaname"])
            )
        }
    }

    func killSessionSQL(processId: String) -> String? {
        guard acceptsProcessId(processId) else { return nil }
        return "ALTER SYSTEM KILL SESSION '\(processId)' IMMEDIATE"
    }

    func cancelQuerySQL(processId: String) -> String? {
        guard hasCancelSQL, acceptsProcessId(processId) else { return nil }
        return "ALTER SYSTEM CANCEL SQL '\(processId)'"
    }

    /// `sid,serial#`: the serial number is what keeps a reused SID from naming the next session.
    func acceptsProcessId(_ processId: String) -> Bool {
        let parts = processId.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

// MARK: - Helpers

private extension OracleDashboardProvider {
    func rateValues(execute: (String) async throws -> QueryResult) async throws -> [String: String] {
        var rates: [String: String] = [:]
        for query in Self.rateQueries {
            let result = try await execute(query)
            for row in result.rows {
                let name = value(row, at: 0)
                if rates[name] == nil { rates[name] = value(row, at: 1) }
            }
            if !rates.isEmpty { break }
        }
        return rates
    }

    func columnIndex(from columns: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            map[name.lowercased()] = index
        }
        return map
    }

    func value(_ row: [PluginCellValue], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].asText ?? ""
    }
}
