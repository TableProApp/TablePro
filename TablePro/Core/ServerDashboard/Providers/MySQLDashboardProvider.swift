//
//  MySQLDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Read from the version banner. MariaDB 5.x shares MySQL's numbers and 10.x is past every floor;
/// an unreadable banner is a current server.
struct MySQLDashboardFeatures: Equatable, Sendable {
    /// `information_schema.PROCESSLIST` arrived in 5.1.7; 5.0.96 answers `1109`.
    let hasProcessListCatalog: Bool
    /// `SHOW GLOBAL STATUS` arrived in 5.0.2; 4.1.22 answers `1064`.
    let hasGlobalStatus: Bool
    /// `KILL QUERY` arrived in 5.0.0; 4.1.22 answers `1204`.
    let hasKillQuery: Bool

    init(serverVersion: String?) {
        let release = Self.release(from: serverVersion)
        hasProcessListCatalog = !Self.isKnown(release, below: [5, 1, 7])
        hasGlobalStatus = !Self.isKnown(release, below: [5, 0, 2])
        hasKillQuery = !Self.isKnown(release, below: [5, 0, 0])
    }

    private static func release(from banner: String?) -> [Int]? {
        let leading = (banner ?? "").prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let parts = leading.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts + Array(repeating: 0, count: 3 - parts.count)
    }

    private static func isKnown(_ release: [Int]?, below floor: [Int]) -> Bool {
        guard let release else { return false }
        return release.lexicographicallyPrecedes(floor)
    }
}

struct MySQLDashboardProvider: ServerDashboardQueryProvider {
    private static let queryTextLimit = 1_000

    private static let sessionsQuery = """
        SELECT ID, USER, DB, COMMAND, TIME, STATE, LEFT(INFO, \(queryTextLimit)) AS INFO
        FROM information_schema.PROCESSLIST
        WHERE ID <> CONNECTION_ID()
        ORDER BY TIME DESC
        """

    private static let slowQueriesQuery = """
        SELECT ID, USER, DB, TIME, LEFT(INFO, \(queryTextLimit)) AS INFO
        FROM information_schema.PROCESSLIST
        WHERE COMMAND <> 'Sleep' AND TIME > 1 AND ID <> CONNECTION_ID()
        ORDER BY TIME DESC
        """

    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]
    let features: MySQLDashboardFeatures

    init(serverVersion: String?) {
        features = MySQLDashboardFeatures(serverVersion: serverVersion)
    }

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let processes: [MySQLProcess]
        if features.hasProcessListCatalog {
            processes = try await catalogProcesses(Self.sessionsQuery, execute: execute)
        } else {
            processes = try await listedProcesses(execute: execute)
        }
        return processes.map { process in
            DashboardSession(
                id: process.id,
                user: process.user,
                database: process.database,
                state: process.state,
                durationSeconds: process.seconds,
                duration: formatDuration(seconds: process.seconds),
                query: process.query
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let statusResult = try await execute(statusQuery)
        var statusMap: [String: String] = [:]
        for row in statusResult.rows {
            let key = value(row, at: 0).lowercased()
            statusMap[key] = value(row, at: 1)
        }

        if let connected = statusMap["threads_connected"] {
            metrics.append(DashboardMetric(
                id: "threads_connected",
                label: String(localized: "Connected Threads"),
                value: connected,
                unit: "",
                icon: "person.2"
            ))
        }

        if let running = statusMap["threads_running"] {
            metrics.append(DashboardMetric(
                id: "threads_running",
                label: String(localized: "Running Threads"),
                value: running,
                unit: "",
                icon: "bolt.horizontal"
            ))
        }

        if let uptimeSecs = statusMap["uptime"], let secs = Int(uptimeSecs) {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: formatDuration(seconds: secs),
                unit: "",
                icon: "clock"
            ))
        }

        if let questions = statusMap["questions"] {
            metrics.append(DashboardMetric(
                id: "questions",
                label: String(localized: "Total Queries"),
                value: questions,
                unit: "",
                icon: "text.magnifyingglass"
            ))
        }

        if let slow = statusMap["slow_queries"] {
            metrics.append(DashboardMetric(
                id: "slow_queries",
                label: String(localized: "Slow Queries"),
                value: slow,
                unit: "",
                icon: "tortoise"
            ))
        }

        let maxConnResult = try await execute("SELECT @@max_connections")
        if let row = maxConnResult.rows.first {
            metrics.append(DashboardMetric(
                id: "max_connections",
                label: String(localized: "Max Connections"),
                value: value(row, at: 0),
                unit: "",
                icon: "person.3"
            ))
        }

        if let received = statusMap["bytes_received"] {
            metrics.append(DashboardMetric(
                id: "bytes_received",
                label: String(localized: "Bytes Received"),
                value: formatBytes(received),
                unit: "",
                icon: "arrow.down.circle"
            ))
        }

        if let sent = statusMap["bytes_sent"] {
            metrics.append(DashboardMetric(
                id: "bytes_sent",
                label: String(localized: "Bytes Sent"),
                value: formatBytes(sent),
                unit: "",
                icon: "arrow.up.circle"
            ))
        }

        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let processes: [MySQLProcess]
        if features.hasProcessListCatalog {
            processes = try await catalogProcesses(Self.slowQueriesQuery, execute: execute)
        } else {
            processes = try await listedProcesses(execute: execute).filter(\.isSlow)
        }
        return processes.map { process in
            DashboardSlowQuery(
                duration: formatDuration(seconds: process.seconds),
                query: process.query,
                user: process.user,
                database: process.database
            )
        }
    }

    func killSessionSQL(processId: String) -> String? {
        guard acceptsProcessId(processId), let id = Int(processId) else { return nil }
        return "KILL \(id)"
    }

    func cancelQuerySQL(processId: String) -> String? {
        guard features.hasKillQuery, acceptsProcessId(processId), let id = Int(processId) else { return nil }
        return "KILL QUERY \(id)"
    }

    func acceptsProcessId(_ processId: String) -> Bool {
        Int(processId) != nil
    }
}

private struct MySQLProcess {
    let id: String
    let user: String
    let database: String
    let command: String
    let state: String
    let seconds: Int
    let query: String

    /// The slow-query catalog filter, `COMMAND <> 'Sleep' AND TIME > 1`, for a server without the catalog.
    var isSlow: Bool {
        command.caseInsensitiveCompare("Sleep") != .orderedSame && seconds > 1
    }
}

// MARK: - Helpers

private extension MySQLDashboardProvider {
    /// Before 5.0.2 `SHOW STATUS` is the server-wide counters, and `GLOBAL` does not parse.
    var statusQuery: String {
        features.hasGlobalStatus ? "SHOW GLOBAL STATUS" : "SHOW STATUS"
    }

    func catalogProcesses(
        _ sql: String,
        execute: (String) async throws -> QueryResult
    ) async throws -> [MySQLProcess] {
        let result = try await execute(sql)
        let col = columnIndex(from: result.columns)
        return result.rows.map { process(from: $0, columns: col) }
    }

    /// `SHOW FULL PROCESSLIST` takes no `WHERE` or `ORDER BY`, so the catalog query's filter and
    /// order run here, and it lists the dashboard's own session too.
    func listedProcesses(execute: (String) async throws -> QueryResult) async throws -> [MySQLProcess] {
        let ownId = try await execute("SELECT CONNECTION_ID()").rows.first.map { value($0, at: 0) }
        let result = try await execute("SHOW FULL PROCESSLIST")
        let col = columnIndex(from: result.columns)
        return result.rows
            .map { process(from: $0, columns: col) }
            .filter { $0.id != ownId }
            .sorted { $0.seconds > $1.seconds }
    }

    func process(from row: [PluginCellValue], columns col: [String: Int]) -> MySQLProcess {
        MySQLProcess(
            id: value(row, at: col["id"]),
            user: value(row, at: col["user"]),
            database: value(row, at: col["db"]),
            command: value(row, at: col["command"]),
            state: value(row, at: col["state"]),
            seconds: Int(value(row, at: col["time"])) ?? 0,
            query: String(value(row, at: col["info"]).prefix(Self.queryTextLimit))
        )
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

    func formatDuration(seconds: Int) -> String {
        DurationFormatting.string(seconds: seconds)
    }

    func formatBytes(_ string: String) -> String {
        ByteSizeFormatting.string(byteString: string)
    }
}
