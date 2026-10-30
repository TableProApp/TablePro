//
//  PostgreSQLDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLDashboardProviderTests {
    private struct QueryFailure: Error {}

    private func catalog(for databaseType: DatabaseType, serverVersion: String?) throws -> PostgreSQLActivityCatalog {
        let provider = ServerDashboardQueryProviderFactory.provider(for: databaseType, serverVersion: serverVersion)
        let postgres = try #require(provider as? PostgreSQLDashboardProvider)
        return postgres.activityCatalog
    }

    private func result(columns: [String], rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows.map { row in row.map { $0.map { PluginCellValue.text($0) } ?? .null } },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    @Test(
        "PostgreSQL picks the pg_stat_activity shape its server version has",
        arguments: [
            ("9.1.24", PostgreSQLActivityCatalog.procpid),
            ("9.2.23", .withoutBackendType),
            ("9.6.24", .withoutBackendType),
            ("10.21", .current),
            ("17.11", .current)
        ]
    )
    func postgresCatalogFollowsVersion(serverVersion: String, expected: PostgreSQLActivityCatalog) throws {
        #expect(try catalog(for: .postgresql, serverVersion: serverVersion) == expected)
    }

    @Test("An unknown PostgreSQL version keeps the current catalog")
    func unknownVersionKeepsCurrent() throws {
        #expect(try catalog(for: .postgresql, serverVersion: nil) == .current)
        #expect(try catalog(for: .postgresql, serverVersion: "unparsable") == .current)
    }

    @Test("Redshift reads the procpid catalog its pg_stat_activity still has, whatever version it reports")
    func redshiftReadsProcpidCatalog() throws {
        #expect(try catalog(for: .redshift, serverVersion: "8.0.2") == .procpid)
        #expect(try catalog(for: .redshift, serverVersion: nil) == .procpid)
        #expect(try catalog(for: .redshift, serverVersion: "17.11") == .procpid)
    }

    @Test("CockroachDB keeps the current catalog whatever version it reports")
    func cockroachKeepsCurrent() throws {
        #expect(try catalog(for: .cockroachdb, serverVersion: "13.0.0") == .current)
    }

    @Test("Redshift never names a pg_stat_activity column that arrived after PostgreSQL 8.0")
    func redshiftAsksOnlyForItsColumns() async throws {
        let provider = try #require(
            ServerDashboardQueryProviderFactory.provider(for: .redshift, serverVersion: "8.0.2")
        )
        var asked: [String] = []
        _ = try await provider.fetchSessions { sql in
            asked.append(sql)
            return .empty
        }
        _ = try await provider.fetchMetrics { sql in
            asked.append(sql)
            return .empty
        }
        _ = try await provider.fetchSlowQueries { sql in
            asked.append(sql)
            return .empty
        }
        let activityQueries = asked.filter { $0.contains("pg_stat_activity") }
        #expect(activityQueries.count == 4)
        for sql in activityQueries {
            #expect(!sql.contains("backend_type"), "\(sql)")
            #expect(!sql.contains("left(query"), "\(sql)")
            #expect(!sql.contains("state ="), "\(sql)")
            #expect(!sql.contains("SELECT pid"), "\(sql)")
        }
    }

    @Test("A session whose command text Redshift could not find is neither active nor slow")
    func commandStringNotFoundIsHidden() {
        let catalog = PostgreSQLActivityCatalog.procpid
        #expect(catalog.activeQueryCountQuery.contains("'<command string not found>'"))
        #expect(catalog.slowQueriesQuery.contains("'<command string not found>'"))
        #expect(catalog.sessionsQuery.contains("WHEN current_query OPERATOR(pg_catalog.=) '<command string not found>' THEN NULL"))
    }

    @Test("Servers before 10 never ask for backend_type")
    func legacyCatalogsSkipBackendType() {
        for catalog in [PostgreSQLActivityCatalog.withoutBackendType, .procpid] {
            let queries = [
                catalog.sessionsQuery, catalog.connectionCountQuery,
                catalog.activeQueryCountQuery, catalog.slowQueriesQuery
            ]
            #expect(queries.allSatisfy { !$0.contains("backend_type") })
        }
    }

    @Test("Servers before 9.2 read procpid and current_query, never pid, state or query")
    func procpidCatalogUsesPreNinePointTwoColumns() {
        let catalog = PostgreSQLActivityCatalog.procpid
        let queries = [catalog.sessionsQuery, catalog.activeQueryCountQuery, catalog.slowQueriesQuery]
        #expect(queries.allSatisfy {
            $0.contains("procpid OPERATOR(pg_catalog.<>) pg_catalog.pg_backend_pid()") && $0.contains("current_query")
        })
        #expect(queries.allSatisfy { !$0.contains("left(query") })
        #expect(catalog.sessionsQuery.contains("SELECT procpid AS pid"))
        #expect(catalog.slowQueriesQuery.contains("SELECT procpid AS pid"))
        #expect(!catalog.slowQueriesQuery.contains("state ="))
        #expect(!catalog.activeQueryCountQuery.contains("state ="))
    }

    @Test("The current catalog filters client backends and active sessions")
    func currentCatalogFilters() {
        let catalog = PostgreSQLActivityCatalog.current
        #expect(catalog.connectionCountQuery == """
            SELECT pg_catalog.count(*) FROM pg_catalog.pg_stat_activity \
            WHERE backend_type OPERATOR(pg_catalog.=) 'client backend'
            """)
        #expect(catalog.sessionsQuery.contains("AND backend_type OPERATOR(pg_catalog.=) 'client backend'"))
        #expect(catalog.slowQueriesQuery.contains("WHERE state OPERATOR(pg_catalog.=) 'active'"))
    }

    // A database owner can set a default search_path that puts its own schema before pg_catalog, where a function,
    // operator or relation of the same name would be read instead.
    @Test("Every dashboard statement names pg_catalog's functions, relations and operators")
    func everyStatementNamesPgCatalog() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current, metricSet: .full)
        var asked: [String] = []
        _ = try await provider.fetchMetrics { sql in
            asked.append(sql)
            return .empty
        }
        for catalog in [PostgreSQLActivityCatalog.current, .withoutBackendType, .procpid] {
            asked += [
                catalog.sessionsQuery, catalog.connectionCountQuery,
                catalog.activeQueryCountQuery, catalog.slowQueriesQuery
            ]
        }
        asked += [provider.killSessionSQL(processId: "42") ?? "", provider.cancelQuerySQL(processId: "42") ?? ""]
        for sql in asked {
            #expect(!sql.contains(" = ") && !sql.contains(" <> ") && !sql.contains(" IN ("), "\(sql)")
            #expect(!sql.contains("FROM pg_stat"), "\(sql)")
            #expect(!sql.contains("SELECT count(") && !sql.contains("(now()"), "\(sql)")
        }
        #expect(provider.killSessionSQL(processId: "42") == "SELECT pg_catalog.pg_terminate_backend(42)")
    }

    @Test("CockroachDB is asked only for the metrics it has")
    func cockroachMetricSet() throws {
        let provider = ServerDashboardQueryProviderFactory.provider(for: .cockroachdb, serverVersion: "13.0.0")
        let postgres = try #require(provider as? PostgreSQLDashboardProvider)
        #expect(postgres.metricSet == .activityOnly)
        #expect(PostgreSQLDashboardMetricSet(databaseType: .postgresql) == .full)
        #expect(PostgreSQLDashboardMetricSet(databaseType: .redshift) == .full)
    }

    @Test("The CockroachDB metric set runs two statements, not five")
    func cockroachRunsTwoStatements() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current, metricSet: .activityOnly)
        var asked: [String] = []
        let metrics = try await provider.fetchMetrics { sql in
            asked.append(sql)
            return result(columns: ["value"], rows: [["2"]])
        }
        #expect(asked.count == 2)
        #expect(metrics.map(\.id) == ["connections", "active_queries"])
        #expect(!asked.contains { $0.contains("pg_size_pretty") || $0.contains("pg_postmaster_start_time") })
    }

    @Test("One failing metric leaves the others on the panel")
    func metricFailureIsIsolated() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        let metrics = try await provider.fetchMetrics { sql in
            if sql.contains("backend_type") { throw QueryFailure() }
            return result(columns: ["value"], rows: [["7"]])
        }
        #expect(metrics.map(\.id) == ["cache_hit", "db_size", "uptime", "active_queries"])
    }

    @Test("The metrics panel fails only when every metric fails")
    func metricsFailWhenAllFail() async {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        await #expect(throws: QueryFailure.self) {
            _ = try await provider.fetchMetrics { _ in throw QueryFailure() }
        }
    }

    @Test("Sessions map pid, state and query from the procpid catalog's aliases")
    func procpidSessionsMap() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .procpid)
        let sessions = try await provider.fetchSessions { _ in
            result(
                columns: ["pid", "usename", "datname", "state", "duration_secs", "query"],
                rows: [["1733", "postgres", "app", "active", "3", "SELECT pg_sleep(12)"]]
            )
        }
        let session = try #require(sessions.first)
        #expect(session.id == "1733")
        #expect(session.state == "active")
        #expect(session.durationSeconds == 3)
        #expect(session.query == "SELECT pg_sleep(12)")
    }
}
