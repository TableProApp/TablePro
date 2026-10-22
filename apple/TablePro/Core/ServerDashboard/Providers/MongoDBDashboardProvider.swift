//
//  MongoDBDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Each panel is a shell statement run read-only in the user's shell, whose globals an earlier
/// statement may have redefined, so it calls only commands the driver counts as reads and declares
/// no global. It returns documents of strings; `command` stays a document so the grid renders it.
struct MongoDBDashboardProvider: ServerDashboardQueryProvider {
    private static let queryTextLimit = 1_000

    let supportedPanels: Set<DashboardPanel> = [.activeSessions, .serverMetrics, .slowQueries]

    /// Drops the session and routing fields a driver adds to every command. `$truncated` is what
    /// `currentOp` leaves of a command over 1 KB, so it stays.
    private static let commandCleanup = """
        function shown(command) {
            if (!command) { return undefined; }
            var kept = {};
            for (var key in command) {
                var added = key.charAt(0) === "$" && key !== "$truncated";
                if (!added && key !== "lsid" && key !== "comment") { kept[key] = command[key]; }
            }
            return kept;
        }
        function text(value) { return value === undefined || value === null ? "" : String(value); }
        """

    /// Without `inprog` the server answers Unauthorized (13) and shows only the account's own
    /// operations. Server threads carry no client address; an awaitable `hello` is driver monitoring.
    static let sessionsStatement = """
        (function () {
            \(commandCleanup)
            function operations(ownOnly) {
                var request = {
                    currentOp: 1,
                    $all: true,
                    "command.currentOp": { $exists: false },
                    "command.maxAwaitTimeMS": { $exists: false },
                    $or: [{ client: { $exists: true } }, { client_s: { $exists: true } }]
                };
                if (ownOnly) { request.$ownOps = true; }
                return db.adminCommand(request).inprog || [];
            }
            var found;
            try {
                found = operations(false);
            } catch (error) {
                if (error.code !== 13) { throw error; }
                found = operations(true);
            }
            return found.map(function (op) {
                var users = op.effectiveUsers || [];
                return {
                    opid: text(op.opid),
                    connection: text(op.desc),
                    user: users.length > 0 ? text(users[0].user) : "",
                    ns: text(op.ns),
                    active: op.active ? "true" : "false",
                    secs: text(op.secs_running),
                    command: shown(op.command)
                };
            });
        })()
        """

    static let metricsStatement = """
        (function () {
            \(commandCleanup)
            var status = db.adminCommand({ serverStatus: 1 });
            var connections = status.connections || {};
            var counters = status.opcounters || {};
            var memory = status.mem || {};
            return [{
                connections: text(connections.current),
                available: text(connections.available),
                uptime: text(Math.floor(Number(status.uptime))),
                resident: text(memory.resident),
                query: text(counters.query),
                insert: text(counters.insert),
                update: text(counters.update),
                remove: text(counters["delete"]),
                command: text(counters.command)
            }];
        })()
        """

    /// The profiler writes to each database's own `system.profile`: this reads the one being browsed.
    static let slowQueriesStatement = """
        (function () {
            \(commandCleanup)
            return db.getCollection("system.profile")
                .find()
                .sort({ ts: -1 })
                .limit(20)
                .toArray()
                .map(function (entry) {
                    return {
                        millis: text(entry.millis),
                        ns: text(entry.ns),
                        user: text(entry.user),
                        command: shown(entry.command)
                    };
                });
        })()
        """

    func fetchSessions(execute: (String) async throws -> QueryResult) async throws -> [DashboardSession] {
        let result = try await execute(Self.sessionsStatement)
        let col = columnIndex(from: result.columns)
        return result.rows.compactMap { row in
            let opid = value(row, at: col["opid"])
            let id = opid.isEmpty ? value(row, at: col["connection"]) : opid
            guard !id.isEmpty else { return nil }
            let isActive = value(row, at: col["active"]) == "true"
            let secs = Int(value(row, at: col["secs"])) ?? 0
            return DashboardSession(
                id: id,
                user: value(row, at: col["user"]),
                database: Self.database(ofNamespace: value(row, at: col["ns"])),
                state: isActive ? "active" : "idle",
                durationSeconds: secs,
                duration: isActive ? DurationFormatting.string(seconds: secs) : "",
                query: String(value(row, at: col["command"]).prefix(Self.queryTextLimit)),
                canKill: false,
                canCancel: isActive && !opid.isEmpty
            )
        }
    }

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        let result = try await execute(Self.metricsStatement)
        guard let row = result.rows.first else { return [] }
        let col = columnIndex(from: result.columns)
        func field(_ name: String) -> String { value(row, at: col[name]) }

        var metrics: [DashboardMetric] = []
        if !field("connections").isEmpty {
            metrics.append(DashboardMetric(
                id: "connections",
                label: String(localized: "Connections"),
                value: field("connections"),
                unit: field("available").isEmpty
                    ? ""
                    : String(format: String(localized: "%@ available"), field("available")),
                icon: "person.2"
            ))
        }
        if let secs = Int(field("uptime")) {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: DurationFormatting.string(seconds: secs),
                unit: "",
                icon: "clock"
            ))
        }
        if let mebibytes = Int64(field("resident")) {
            metrics.append(DashboardMetric(
                id: "resident_memory",
                label: String(localized: "Resident Memory"),
                value: ByteSizeFormatting.string(bytes: mebibytes * 1_048_576),
                unit: "",
                icon: "memorychip"
            ))
        }
        let counters: [(id: String, field: String, label: String, icon: String)] = [
            ("queries", "query", String(localized: "Queries"), "magnifyingglass"),
            ("inserts", "insert", String(localized: "Inserts"), "plus.square"),
            ("updates", "update", String(localized: "Updates"), "pencil"),
            ("deletes", "remove", String(localized: "Deletes"), "trash"),
            ("commands", "command", String(localized: "Commands"), "terminal"),
        ]
        for counter in counters where !field(counter.field).isEmpty {
            metrics.append(DashboardMetric(
                id: counter.id,
                label: counter.label,
                value: field(counter.field),
                unit: "",
                icon: counter.icon
            ))
        }
        return metrics
    }

    func fetchSlowQueries(execute: (String) async throws -> QueryResult) async throws -> [DashboardSlowQuery] {
        let result = try await execute(Self.slowQueriesStatement)
        let col = columnIndex(from: result.columns)
        return result.rows.map { row in
            let millis = Int(value(row, at: col["millis"])) ?? 0
            return DashboardSlowQuery(
                duration: DurationFormatting.string(microseconds: millis * 1_000),
                query: String(value(row, at: col["command"]).prefix(Self.queryTextLimit)),
                user: value(row, at: col["user"]),
                database: Self.database(ofNamespace: value(row, at: col["ns"]))
            )
        }
    }

    /// `killOp` stops an operation and leaves its connection open, which is Cancel Query. MongoDB has
    /// no command that closes another client's connection.
    func cancelQuerySQL(processId: String) -> String? {
        guard acceptsProcessId(processId) else { return nil }
        if Int(processId) != nil {
            return "db.adminCommand({ killOp: 1, op: \(processId) })"
        }
        return "db.adminCommand({ killOp: 1, op: \"\(processId)\" })"
    }

    /// A number on a `mongod`; `shard:number` on a `mongos`, where shard names keep to letters,
    /// digits, `-`, `_` and `.`.
    func acceptsProcessId(_ processId: String) -> Bool {
        if Self.isDigits(processId[...]) { return true }
        let parts = processId.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isDigits(parts[1]), !parts[0].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    static func database(ofNamespace namespace: String) -> String {
        guard let dot = namespace.firstIndex(of: ".") else { return namespace }
        return String(namespace[..<dot])
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Helpers

private extension MongoDBDashboardProvider {
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
