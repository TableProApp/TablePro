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

    // KingbaseES V9R1C10 reports server_version 12.1 in both modes and answers all five metrics.
    @Test("KingbaseES reads the current catalog and every metric")
    func kingbaseReadsCurrentCatalog() throws {
        let provider = ServerDashboardQueryProviderFactory.provider(for: .kingbasees, serverVersion: "12.1")
        let postgres = try #require(provider as? PostgreSQLDashboardProvider)
        #expect(postgres.activityCatalog == .current)
        #expect(postgres.metricSet == .full)
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
        var plan = DashboardFetchPlan()
        _ = await provider.fetchSnapshot(plan: &plan, now: .now, readsEveryMetric: true) { sql in
            asked.append(sql)
            throw QueryFailure()
        }
        for catalog in [PostgreSQLActivityCatalog.current, .withoutBackendType, .procpid] {
            asked += [
                catalog.sessionsQuery, catalog.connectionCountQuery,
                catalog.activeQueryCountQuery, catalog.slowQueriesQuery, catalog.activityQuery
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

    // MARK: - Snapshot

    private static let activityColumns = [
        "pid", "usename", "datname", "state", "duration_secs", "query", "is_own", "is_client", "is_active", "is_slow"
    ]

    // The dashboard's own connection, an idle client, a slow client, a client that just started, a walsender and a
    // parallel worker. The single queries would read: 4 connections (own included), 3 sessions, 4 active and 2 slow.
    private static let activityRows: [[String?]] = [
        ["100", "me", "app", "active", "0", "SELECT ...", "1", "1", "1", "0"],
        ["101", "app", "app", "idle", "40", "COMMIT", "0", "1", "0", "0"],
        ["102", "app", "app", "active", "12", "SELECT pg_sleep(20)", "0", "1", "1", "1"],
        ["103", "app", "app", "active", "0", "SELECT 1", "0", "1", "1", "0"],
        ["104", "replicator", nil, "active", "900", "", "0", "0", "1", "1"],
        ["105", "app", "app", "active", "0", "SELECT 1", "0", "0", "1", "0"],
    ]

    private final class Recorder: @unchecked Sendable {
        var asked: [String] = []
        var refusesCombined = false
        var refusesEverything = false
    }

    private func execute(_ recorder: Recorder) -> (String) async throws -> QueryResult {
        { [self] sql in
            recorder.asked.append(sql)
            if recorder.refusesEverything { throw QueryFailure() }
            if sql.contains("is_own") {
                if recorder.refusesCombined { throw QueryFailure() }
                return result(columns: Self.activityColumns, rows: Self.activityRows)
            }
            if sql.hasPrefix("SELECT (") {
                if recorder.refusesCombined { throw QueryFailure() }
                return result(columns: ["cache_hit", "uptime"], rows: [["99.5", "3 days 02:00:00"]])
            }
            if sql.contains("pg_database_size") {
                return result(columns: ["size"], rows: [["42 MB"]])
            }
            if sql.contains("blks_hit") {
                return result(columns: ["value"], rows: [["99.5"]])
            }
            if sql.contains("pg_postmaster_start_time") {
                return result(columns: ["value"], rows: [["3 days 02:00:00"]])
            }
            if sql.contains("SELECT pid") {
                return result(
                    columns: ["pid", "usename", "datname", "state", "duration_secs", "query"],
                    rows: [["101", "app", "app", "idle", "40", "COMMIT"]]
                )
            }
            return result(columns: ["count"], rows: [["4"]])
        }
    }

    @Test("A snapshot draws sessions, slow queries and both counts from one read, as the single queries filter")
    func snapshotMatchesTheSingleQueries() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        let recorder = Recorder()
        var plan = DashboardFetchPlan()
        let snapshot = await provider.fetchSnapshot(plan: &plan, now: .now, readsEveryMetric: false, execute: execute(recorder))

        let sessions = try #require(try snapshot.sessions?.get())
        #expect(sessions.map { $0.id } == ["101", "102", "103"])
        let slow = try #require(try snapshot.slowQueries?.get())
        #expect(slow.map { $0.query } == ["SELECT pg_sleep(20)", ""])
        let metrics = try #require(try snapshot.metrics?.get())
        #expect(metrics.map { $0.id } == ["connections", "cache_hit", "db_size", "uptime", "active_queries"])
        let values = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0.value) })
        #expect(values["connections"] == "4")
        #expect(values["active_queries"] == "4")
        #expect(values["cache_hit"] == "99.5")
        #expect(values["uptime"] == "3 days 02:00:00")
        #expect(values["db_size"] == "42 MB")
        #expect(recorder.asked.count == 3)
    }

    @Test("The database size is read once a minute and on Refresh Now, and keeps its value in between")
    func sizeIsReadOnceAMinute() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        let recorder = Recorder()
        var plan = DashboardFetchPlan()
        let start = ContinuousClock.now

        _ = await provider.fetchSnapshot(plan: &plan, now: start, readsEveryMetric: false, execute: execute(recorder))
        #expect(recorder.asked.count == 3)

        recorder.asked = []
        let later = await provider.fetchSnapshot(
            plan: &plan, now: start + .seconds(30), readsEveryMetric: false, execute: execute(recorder)
        )
        #expect(recorder.asked.count == 2)
        #expect(!recorder.asked.contains { $0.contains("pg_database_size") })
        let metrics = try #require(try later.metrics?.get())
        #expect(metrics.first { $0.id == "db_size" }?.value == "42 MB")

        recorder.asked = []
        _ = await provider.fetchSnapshot(
            plan: &plan, now: start + .seconds(31), readsEveryMetric: true, execute: execute(recorder)
        )
        #expect(recorder.asked.contains { $0.contains("pg_database_size") })

        recorder.asked = []
        _ = await provider.fetchSnapshot(
            plan: &plan, now: start + .seconds(61), readsEveryMetric: false, execute: execute(recorder)
        )
        #expect(!recorder.asked.contains { $0.contains("pg_database_size") })

        recorder.asked = []
        _ = await provider.fetchSnapshot(
            plan: &plan, now: start + .seconds(92), readsEveryMetric: false, execute: execute(recorder)
        )
        #expect(recorder.asked.contains { $0.contains("pg_database_size") })
    }

    @Test("A refused combined read falls back to the singles, and the next refresh sends only the singles")
    func refusedCombinedReadIsRemembered() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        let recorder = Recorder()
        recorder.refusesCombined = true
        var plan = DashboardFetchPlan()
        let start = ContinuousClock.now

        let first = await provider.fetchSnapshot(plan: &plan, now: start, readsEveryMetric: false, execute: execute(recorder))
        #expect(try first.sessions?.get().map { $0.id } == ["101"])
        #expect(try first.metrics?.get().count == 5)
        #expect(plan.combinedActivityRefused)
        #expect(plan.combinedSummaryRefused)

        recorder.asked = []
        _ = await provider.fetchSnapshot(
            plan: &plan, now: start + .seconds(5), readsEveryMetric: false, execute: execute(recorder)
        )
        #expect(!recorder.asked.contains { $0.contains("is_own") || $0.hasPrefix("SELECT (") })
        #expect(recorder.asked.count == 6)

        var fresh = DashboardFetchPlan()
        recorder.asked = []
        recorder.refusesCombined = false
        _ = await provider.fetchSnapshot(plan: &fresh, now: start + .seconds(10), readsEveryMetric: false, execute: execute(recorder))
        #expect(recorder.asked.first?.contains("is_own") == true)
        #expect(!fresh.combinedActivityRefused)
    }

    @Test("A read that fails everywhere is not remembered as a refusal")
    func failingServerIsNotARefusal() async {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current)
        let recorder = Recorder()
        recorder.refusesEverything = true
        var plan = DashboardFetchPlan()
        let snapshot = await provider.fetchSnapshot(plan: &plan, now: .now, readsEveryMetric: false, execute: execute(recorder))

        #expect(!plan.combinedActivityRefused)
        #expect(!plan.combinedSummaryRefused)
        if case .failure = snapshot.sessions {} else { Issue.record("sessions should fail") }
        if case .failure = snapshot.metrics {} else { Issue.record("metrics should fail") }
    }

    @Test("CockroachDB refreshes in one statement")
    func cockroachSnapshotIsOneStatement() async throws {
        let provider = PostgreSQLDashboardProvider(activityCatalog: .current, metricSet: .activityOnly)
        let recorder = Recorder()
        var plan = DashboardFetchPlan()
        let snapshot = await provider.fetchSnapshot(plan: &plan, now: .now, readsEveryMetric: true, execute: execute(recorder))

        #expect(recorder.asked.count == 1)
        #expect(try snapshot.metrics?.get().map { $0.id } == ["connections", "active_queries"])
    }

    @Test("The combined reads for older servers name only the columns they have")
    func combinedReadsFollowTheCatalog() {
        for catalog in [PostgreSQLActivityCatalog.withoutBackendType, .procpid] {
            #expect(!catalog.activityQuery.contains("backend_type"))
        }
        let procpid = PostgreSQLActivityCatalog.procpid.activityQuery
        #expect(procpid.contains("SELECT procpid AS pid"))
        #expect(!procpid.contains("left(query"))
        #expect(!procpid.contains("state OPERATOR"))
        #expect(procpid.contains("'<command string not found>'"))
    }
}
