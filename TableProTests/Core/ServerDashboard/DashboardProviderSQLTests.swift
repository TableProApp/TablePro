//
//  DashboardProviderSQLTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DashboardProviderSQLTests {
    private final class StatementRecorder {
        private(set) var statements: [String] = []

        func record(_ sql: String) -> QueryResult {
            statements.append(sql)
            return .empty
        }
    }

    private struct LabeledProvider {
        let label: String
        let provider: ServerDashboardQueryProvider
    }

    private struct ServerRelease: Sendable {
        let databaseType: DatabaseType
        let version: String
    }

    private static let currentServerVersions: [DatabaseType: String] = [
        .postgresql: "17.11",
        .clickhouse: "25.8.33.6"
    ]

    private static let olderServerReleases = [
        ServerRelease(databaseType: .postgresql, version: "9.1.24"),
        ServerRelease(databaseType: .postgresql, version: "9.6.24"),
        ServerRelease(databaseType: .clickhouse, version: "21.8.15.7")
    ]

    private static let callerExclusions = ["pg_backend_pid()", "CONNECTION_ID()", "@@SPID", "queryID()"]

    private static func labeledProvider(_ databaseType: DatabaseType, serverVersion: String?) -> LabeledProvider? {
        ServerDashboardQueryProviderFactory.provider(for: databaseType, serverVersion: serverVersion).map {
            LabeledProvider(label: "\(databaseType.rawValue) \(serverVersion ?? "unreported")", provider: $0)
        }
    }

    private static func currentProviders() -> [LabeledProvider] {
        DatabaseType.allKnownTypes.compactMap { labeledProvider($0, serverVersion: currentServerVersions[$0]) }
    }

    private static func everyProvider() -> [LabeledProvider] {
        currentProviders() + olderServerReleases.compactMap {
            labeledProvider($0.databaseType, serverVersion: $0.version)
        }
    }

    private static func statements(sentBy provider: ServerDashboardQueryProvider) async throws -> [String] {
        let recorder = StatementRecorder()
        _ = try await provider.fetchSessions { recorder.record($0) }
        _ = try await provider.fetchMetrics { recorder.record($0) }
        _ = try await provider.fetchSlowQueries { recorder.record($0) }
        return recorder.statements
    }

    private static func sessionsStatement(sentBy provider: ServerDashboardQueryProvider) async throws -> String {
        let recorder = StatementRecorder()
        _ = try await provider.fetchSessions { recorder.record($0) }
        return try #require(recorder.statements.first)
    }

    private static func sessionsStatement(
        for databaseType: DatabaseType,
        serverVersion: String?
    ) async throws -> String {
        let provider = try #require(
            ServerDashboardQueryProviderFactory.provider(for: databaseType, serverVersion: serverVersion)
        )
        return try await sessionsStatement(sentBy: provider)
    }

    private static func slowQueriesStatement(for databaseType: DatabaseType) async throws -> String {
        let provider = try #require(
            ServerDashboardQueryProviderFactory.provider(for: databaseType, serverVersion: nil)
        )
        let recorder = StatementRecorder()
        _ = try await provider.fetchSlowQueries { recorder.record($0) }
        return try #require(recorder.statements.first)
    }

    @Test("Every sessions panel on a current server leaves the dashboard's own session out of the list")
    func sessionsLeaveOutTheCaller() async throws {
        let listing = Self.currentProviders().filter { $0.provider.supportedPanels.contains(.activeSessions) }
        #expect(listing.count >= 6, "Only \(listing.count) engines list sessions; the walk would pass vacuously")
        for entry in listing {
            let sql = try await Self.sessionsStatement(sentBy: entry.provider)
            #expect(
                Self.callerExclusions.contains { sql.contains($0) },
                "\(entry.label) lists the dashboard's own session: \(sql)"
            )
        }
    }

    @Test("SQL Server leaves out the session the dashboard runs on")
    func mssqlLeavesOutItsOwnSession() async throws {
        let sql = try await Self.sessionsStatement(for: .mssql, serverVersion: nil)
        #expect(sql.contains("s.session_id <> @@SPID"))
    }

    @Test("SQL Server leaves the dashboard's own request out of Slow Queries")
    func mssqlSlowQueriesLeaveOutItsOwnRequest() async throws {
        let sql = try await Self.slowQueriesStatement(for: .mssql)
        #expect(sql.contains("s.session_id <> @@SPID"))
    }

    @Test(
        "ClickHouse 21.9 and newer leaves out the query that reads system.processes",
        arguments: ["21.9.2.17", "21.10.6.2", "22.3.20.29", "25.8.33.6"]
    )
    func clickHouseLeavesOutItsOwnQuery(serverVersion: String) async throws {
        let sql = try await Self.sessionsStatement(for: .clickhouse, serverVersion: serverVersion)
        #expect(sql.contains("WHERE query_id != queryID()"))
    }

    @Test(
        "ClickHouse before 21.9, or with no version to read, never calls queryID()",
        arguments: ["21.8.15.7", "20.3.21.2", "unparsable", nil] as [String?]
    )
    func olderClickHouseNeverCallsQueryID(serverVersion: String?) async throws {
        let sql = try await Self.sessionsStatement(for: .clickhouse, serverVersion: serverVersion)
        #expect(!sql.contains("queryID()"))
        #expect(sql.contains("FROM system.processes"))
    }

    @Test("Every dashboard statement is free of Swift digit separators")
    func noStatementCarriesADigitSeparator() async throws {
        let providers = Self.everyProvider()
        #expect(providers.count >= 10, "Only \(providers.count) providers; the walk would pass vacuously")
        for entry in providers {
            let statements = try await Self.statements(sentBy: entry.provider)
            #expect(!statements.isEmpty, "\(entry.label) sent nothing")
            for sql in statements {
                #expect(
                    sql.range(of: #"\d_\d"#, options: .regularExpression) == nil,
                    "\(entry.label) sends a digit separator the server reads as an identifier: \(sql)"
                )
            }
        }
    }
}
