//
//  RedisDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProRedisCore

/// Every command goes out as `OUTSIDEBLOCK`, held back instead of queued while the user has a MULTI
/// block open: queued, the reads would land in the user's EXEC, and a refused one would abort it.
/// On a cluster every command but SLOWLOG GET reaches the same primary, so the panels describe it.
struct RedisDashboardProvider: ServerDashboardQueryProvider {
    static let slowLogLength = 20
    private static let queryTextLimit = 1_000

    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    /// CLIENT UNBLOCK arrived in Redis 5.0.
    let hasClientUnblock: Bool

    init(serverVersion: String?) {
        let major = serverVersion?.split(separator: ".").first.flatMap { Int($0) }
        hasClientUnblock = major.map { $0 >= 5 } ?? true
    }

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        // CLIENT ID arrived in Redis 5.0; before that the dashboard's own connection stays listed.
        let ownId = try? await firstCell(of: execute("OUTSIDEBLOCK CLIENT ID"))
        let listing = try await firstCell(of: execute("OUTSIDEBLOCK CLIENT LIST"))
        return Self.clients(in: listing).compactMap { client in
            guard let id = client["id"], !id.isEmpty, id != ownId else { return nil }
            let idle = Int(client["idle"] ?? "") ?? 0
            let state = Self.state(flags: client["flags"] ?? "", idleSeconds: idle)
            return DashboardSession(
                id: id,
                user: client["user"] ?? "",
                database: client["db"].map { "db\($0)" } ?? "",
                state: state,
                durationSeconds: idle,
                duration: DurationFormatting.string(seconds: idle),
                query: client["cmd"] ?? "",
                canCancel: hasClientUnblock && state == Self.blockedState
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        let info = try await firstCell(of: execute("OUTSIDEBLOCK INFO"))
        func field(_ key: String) -> String? { RedisServerInfo.value(key, in: info) }

        var metrics: [DashboardMetric] = []
        if let clients = field("connected_clients") {
            metrics.append(DashboardMetric(
                id: "connected_clients",
                label: String(localized: "Connected Clients"),
                value: clients,
                unit: "",
                icon: "person.2"
            ))
        }
        if let used = field("used_memory").flatMap(Int64.init) {
            let limit = field("maxmemory").flatMap(Int64.init) ?? 0
            metrics.append(DashboardMetric(
                id: "used_memory",
                label: String(localized: "Used Memory"),
                value: ByteSizeFormatting.string(bytes: used),
                unit: limit > 0 ? Self.share(used, of: limit) : "",
                icon: "memorychip"
            ))
        }
        if let operations = field("instantaneous_ops_per_sec") {
            metrics.append(DashboardMetric(
                id: "operations",
                label: String(localized: "Operations"),
                value: operations,
                unit: String(localized: "per second"),
                icon: "arrow.left.arrow.right"
            ))
        }
        if let hits = field("keyspace_hits").flatMap(Double.init),
           let misses = field("keyspace_misses").flatMap(Double.init) {
            let lookups = hits + misses
            metrics.append(DashboardMetric(
                id: "keyspace_hit_ratio",
                label: String(localized: "Keyspace Hit Ratio"),
                value: lookups > 0 ? String(format: "%.1f", hits / lookups * 100) : "0",
                unit: "%",
                icon: "bolt"
            ))
        }
        if let uptime = field("uptime_in_seconds").flatMap(Int.init) {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: DurationFormatting.string(seconds: uptime),
                unit: "",
                icon: "clock"
            ))
        }
        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let result = try await execute("OUTSIDEBLOCK SLOWLOG GET \(Self.slowLogLength)")
        let col = columnIndex(from: result.columns)
        let entries = result.rows.map { row in
            (
                time: Int(value(row, at: col[RedisSlowLogGrid.time.lowercased()])) ?? 0,
                microseconds: Int(value(row, at: col[RedisSlowLogGrid.durationMicroseconds.lowercased()])) ?? 0,
                command: value(row, at: col[RedisSlowLogGrid.command.lowercased()]),
                client: value(row, at: col[RedisSlowLogGrid.client.lowercased()])
            )
        }
        // A cluster answers with each node's log in turn, so the newest across them are picked here.
        return entries
            .sorted { $0.time > $1.time }
            .prefix(Self.slowLogLength)
            .map { entry in
                DashboardSlowQuery(
                    duration: DurationFormatting.string(microseconds: entry.microseconds),
                    query: String(entry.command.prefix(Self.queryTextLimit)),
                    user: entry.client,
                    database: ""
                )
            }
    }

    func killSessionSQL(processId: String) -> String? {
        guard acceptsProcessId(processId) else { return nil }
        return "OUTSIDEBLOCK CLIENT KILL ID \(processId)"
    }

    /// Only a client blocked in BLPOP, XREAD or the like has a command still running. ERROR ends the
    /// wait with an error reply and leaves the connection open.
    func cancelQuerySQL(processId: String) -> String? {
        guard hasClientUnblock, acceptsProcessId(processId) else { return nil }
        return "OUTSIDEBLOCK CLIENT UNBLOCK \(processId) ERROR"
    }

    func acceptsProcessId(_ processId: String) -> Bool {
        !processId.isEmpty && processId.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// One `key=value` field per space, one client per line. Redis refuses a space in a client name.
    static func clients(in listing: String) -> [[String: String]] {
        listing.split(whereSeparator: \.isNewline).map { line in
            var fields: [String: String] = [:]
            for pair in line.split(separator: " ") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }
            return fields
        }
    }

    static let blockedState = "blocked"

    static func state(flags: String, idleSeconds: Int) -> String {
        if flags.contains("b") { return blockedState }
        if flags.contains("x") { return "multi" }
        if flags.contains("P") { return "pubsub" }
        if flags.contains("S") { return "replica" }
        if flags.contains("M") { return "master" }
        return idleSeconds > 0 ? "idle" : "active"
    }

    private static func share(_ used: Int64, of limit: Int64) -> String {
        let share = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(0)))
        return String(format: String(localized: "%@ used"), share)
    }
}

// MARK: - Helpers

private extension RedisDashboardProvider {
    func firstCell(of result: QueryResult) -> String {
        result.rows.first?.first?.asText ?? ""
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
