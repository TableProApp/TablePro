//
//  MSSQLDashboardProvider.swift
//  TablePro
//

import Foundation

struct MSSQLDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let sql = """
            SELECT s.session_id, s.login_name, DB_NAME(s.database_id) AS db_name,
                   s.status, r.total_elapsed_time AS duration_ms,
                   r.command, LEFT(t.text, 1000) AS query_text
            FROM sys.dm_exec_sessions s
            LEFT JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
            WHERE s.is_user_process = 1
            ORDER BY r.total_elapsed_time DESC
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = (Int(value(row, at: col["duration_ms"])) ?? 0) / 1_000
            return DashboardSession(
                id: value(row, at: col["session_id"]),
                user: value(row, at: col["login_name"]),
                database: value(row, at: col["db_name"]),
                state: value(row, at: col["status"]),
                durationSeconds: secs,
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query_text"]),
                canCancel: false
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let connResult = try await execute(
            "SELECT count(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1"
        )
        if let row = connResult.rows.first {
            metrics.append(DashboardMetric(
                id: "connections",
                label: String(localized: "User Sessions"),
                value: value(row, at: 0),
                unit: "",
                icon: "person.2"
            ))
        }

        let uptimeResult = try await execute("""
            SELECT DATEDIFF(SECOND, sqlserver_start_time, GETDATE()) AS uptime_secs
            FROM sys.dm_os_sys_info
            """)
        if let row = uptimeResult.rows.first {
            let secs = Int(value(row, at: 0)) ?? 0
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: formatDuration(seconds: secs),
                unit: "",
                icon: "clock"
            ))
        }

        let sizeResult = try await execute("""
            SELECT SUM(size * 8 / 1024) AS size_mb FROM sys.database_files
            """)
        if let row = sizeResult.rows.first {
            let sizeMb = value(row, at: 0)
            metrics.append(DashboardMetric(
                id: "db_size",
                label: String(localized: "Database Size"),
                value: "\(sizeMb) MB",
                unit: "",
                icon: "internaldrive"
            ))
        }

        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let sql = """
            SELECT s.session_id, s.login_name, DB_NAME(s.database_id) AS db_name,
                   r.total_elapsed_time AS duration_ms,
                   LEFT(t.text, 1000) AS query_text
            FROM sys.dm_exec_sessions s
            JOIN sys.dm_exec_requests r ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
            WHERE s.is_user_process = 1 AND r.total_elapsed_time > 1_000
            ORDER BY r.total_elapsed_time DESC
            """
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let secs = (Int(value(row, at: col["duration_ms"])) ?? 0) / 1_000
            return DashboardSlowQuery(
                duration: formatDuration(seconds: secs),
                query: value(row, at: col["query_text"]),
                user: value(row, at: col["login_name"]),
                database: value(row, at: col["db_name"])
            )
        }
    }

    func killSessionSQL(processId: String) -> String? {
        guard let spid = Int(processId) else { return nil }
        return "KILL \(spid)"
    }
}

// MARK: - Helpers

private extension MSSQLDashboardProvider {
    func columnIndex(from columns: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            map[name.lowercased()] = index
        }
        return map
    }

    func value(_ row: [String?], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index] ?? ""
    }

    func formatDuration(seconds: Int) -> String {
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
        } else if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }
}
