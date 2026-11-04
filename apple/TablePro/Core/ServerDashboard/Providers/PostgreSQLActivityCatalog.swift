//
//  PostgreSQLActivityCatalog.swift
//  TablePro
//

import Foundation

/// Which of the five metrics an engine can answer.
///
/// CockroachDB reports a PostgreSQL version and `pg_stat_activity`, but `pg_size_pretty()`,
/// `pg_database_size()` and `pg_postmaster_start_time()` are unknown functions there (measured on
/// v26.2), so asking for them every tick is three failed statements per refresh.
enum PostgreSQLDashboardMetricSet: Equatable, Sendable {
    case full
    case activityOnly

    init(databaseType: DatabaseType) {
        self = databaseType == .cockroachdb ? .activityOnly : .full
    }

    var identifiers: Set<String> {
        switch self {
        case .full:
            return ["connections", "cache_hit", "db_size", "uptime", "active_queries"]
        case .activityOnly:
            return ["connections", "active_queries"]
        }
    }
}

enum PostgreSQLActivityCatalog: Equatable, Sendable {
    case current
    case withoutBackendType
    case procpid

    init(serverVersion: PostgreSQLServerVersion?) {
        guard let serverVersion else {
            self = .current
            return
        }
        if serverVersion >= .backendTypeColumn {
            self = .current
        } else if serverVersion >= .stateColumns {
            self = .withoutBackendType
        } else {
            self = .procpid
        }
    }

    private static let idleSentinels = [
        "<IDLE>",
        "<IDLE> in transaction",
        "<IDLE> in transaction (aborted)"
    ]

    private static let hiddenSentinels = idleSentinels + [
        "<insufficient privilege>",
        "<command string not enabled>",
        "<command string not found>"
    ]

    private static func literalList(_ values: [String]) -> String {
        values.map { "'\($0)'" }.joined(separator: ", ")
    }

    // The dashboard reads on the user's session, whose path may name another schema before pg_catalog, so every
    // function, relation, type and operator here names pg_catalog. A CASE with an operand or an IN list would look its
    // equality operator up on that path.
    private static func isAny(_ column: String, of values: [String]) -> String {
        "\(column) OPERATOR(pg_catalog.=) ANY (ARRAY[\(literalList(values))]::pg_catalog.text[])"
    }

    private static let duration =
        "EXTRACT(EPOCH FROM (pg_catalog.now() OPERATOR(pg_catalog.-) query_start))::pg_catalog.int4 AS duration_secs"

    var sessionsQuery: String {
        switch self {
        case .current:
            return """
                SELECT pid, usename, datname, state,
                       \(Self.duration),
                       pg_catalog.left(query, 1000) AS query
                FROM pg_catalog.pg_stat_activity
                WHERE pid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                  AND backend_type OPERATOR(pg_catalog.=) 'client backend'
                ORDER BY query_start NULLS LAST
                """
        case .withoutBackendType:
            return """
                SELECT pid, usename, datname, state,
                       \(Self.duration),
                       pg_catalog.left(query, 1000) AS query
                FROM pg_catalog.pg_stat_activity
                WHERE pid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                ORDER BY query_start NULLS LAST
                """
        case .procpid:
            return """
                SELECT procpid AS pid, usename, datname,
                       CASE
                           WHEN current_query OPERATOR(pg_catalog.=) '<IDLE>' THEN 'idle'
                           WHEN current_query OPERATOR(pg_catalog.=) '<IDLE> in transaction' THEN 'idle in transaction'
                           WHEN current_query OPERATOR(pg_catalog.=) '<IDLE> in transaction (aborted)'
                               THEN 'idle in transaction (aborted)'
                           WHEN current_query OPERATOR(pg_catalog.=) '<command string not enabled>' THEN 'disabled'
                           WHEN current_query OPERATOR(pg_catalog.=) '<insufficient privilege>' THEN NULL
                           WHEN current_query OPERATOR(pg_catalog.=) '<command string not found>' THEN NULL
                           ELSE 'active'
                       END AS state,
                       \(Self.duration),
                       CASE WHEN \(Self.isAny("current_query", of: Self.idleSentinels)) THEN ''
                            ELSE pg_catalog.left(current_query, 1000)
                       END AS query
                FROM pg_catalog.pg_stat_activity
                WHERE procpid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                ORDER BY query_start NULLS LAST
                """
        }
    }

    var connectionCountQuery: String {
        switch self {
        case .current:
            return "SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity "
                + "WHERE backend_type OPERATOR(pg_catalog.=) 'client backend'"
        case .withoutBackendType, .procpid:
            return "SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity"
        }
    }

    var activeQueryCountQuery: String {
        switch self {
        case .current, .withoutBackendType:
            return """
                SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity
                WHERE state OPERATOR(pg_catalog.=) 'active' AND pid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                """
        case .procpid:
            return """
                SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity
                WHERE NOT \(Self.isAny("current_query", of: Self.hiddenSentinels))
                  AND procpid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                """
        }
    }

    var slowQueriesQuery: String {
        switch self {
        case .current, .withoutBackendType:
            return """
                SELECT pid, usename, datname,
                       \(Self.duration),
                       pg_catalog.left(query, 1000) AS query
                FROM pg_catalog.pg_stat_activity
                WHERE state OPERATOR(pg_catalog.=) 'active'
                  AND (pg_catalog.now() OPERATOR(pg_catalog.-) query_start) OPERATOR(pg_catalog.>) INTERVAL '1 second'
                  AND pid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                ORDER BY query_start
                """
        case .procpid:
            return """
                SELECT procpid AS pid, usename, datname,
                       \(Self.duration),
                       pg_catalog.left(current_query, 1000) AS query
                FROM pg_catalog.pg_stat_activity
                WHERE NOT \(Self.isAny("current_query", of: Self.hiddenSentinels))
                  AND (pg_catalog.now() OPERATOR(pg_catalog.-) query_start) OPERATOR(pg_catalog.>) INTERVAL '1 second'
                  AND procpid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()
                ORDER BY query_start
                """
        }
    }
}
