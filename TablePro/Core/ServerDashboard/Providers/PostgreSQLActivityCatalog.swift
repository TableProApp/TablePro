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
        "<command string not enabled>"
    ]

    private static func literalList(_ values: [String]) -> String {
        values.map { "'\($0)'" }.joined(separator: ", ")
    }

    var sessionsQuery: String {
        switch self {
        case .current:
            return """
                SELECT pid, usename, datname, state,
                       EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                       left(query, 1000) AS query
                FROM pg_stat_activity
                WHERE pid <> pg_backend_pid()
                  AND backend_type = 'client backend'
                ORDER BY query_start NULLS LAST
                """
        case .withoutBackendType:
            return """
                SELECT pid, usename, datname, state,
                       EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                       left(query, 1000) AS query
                FROM pg_stat_activity
                WHERE pid <> pg_backend_pid()
                ORDER BY query_start NULLS LAST
                """
        case .procpid:
            return """
                SELECT procpid AS pid, usename, datname,
                       CASE current_query
                           WHEN '<IDLE>' THEN 'idle'
                           WHEN '<IDLE> in transaction' THEN 'idle in transaction'
                           WHEN '<IDLE> in transaction (aborted)' THEN 'idle in transaction (aborted)'
                           WHEN '<command string not enabled>' THEN 'disabled'
                           WHEN '<insufficient privilege>' THEN NULL
                           ELSE 'active'
                       END AS state,
                       EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                       CASE WHEN current_query IN (\(Self.literalList(Self.idleSentinels))) THEN ''
                            ELSE left(current_query, 1000)
                       END AS query
                FROM pg_stat_activity
                WHERE procpid <> pg_backend_pid()
                ORDER BY query_start NULLS LAST
                """
        }
    }

    var connectionCountQuery: String {
        switch self {
        case .current:
            return "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'"
        case .withoutBackendType, .procpid:
            return "SELECT count(*) FROM pg_stat_activity"
        }
    }

    var activeQueryCountQuery: String {
        switch self {
        case .current, .withoutBackendType:
            return """
                SELECT count(*) FROM pg_stat_activity
                WHERE state = 'active' AND pid <> pg_backend_pid()
                """
        case .procpid:
            return """
                SELECT count(*) FROM pg_stat_activity
                WHERE current_query NOT IN (\(Self.literalList(Self.hiddenSentinels)))
                  AND procpid <> pg_backend_pid()
                """
        }
    }

    var slowQueriesQuery: String {
        switch self {
        case .current, .withoutBackendType:
            return """
                SELECT pid, usename, datname,
                       EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                       left(query, 1000) AS query
                FROM pg_stat_activity
                WHERE state = 'active'
                  AND now() - query_start > interval '1 second'
                  AND pid <> pg_backend_pid()
                ORDER BY query_start
                """
        case .procpid:
            return """
                SELECT procpid AS pid, usename, datname,
                       EXTRACT(EPOCH FROM (now() - query_start))::int AS duration_secs,
                       left(current_query, 1000) AS query
                FROM pg_stat_activity
                WHERE current_query NOT IN (\(Self.literalList(Self.hiddenSentinels)))
                  AND now() - query_start > interval '1 second'
                  AND procpid <> pg_backend_pid()
                ORDER BY query_start
                """
        }
    }
}
