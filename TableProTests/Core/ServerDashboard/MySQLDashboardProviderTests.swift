//
//  MySQLDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MySQLDashboardProviderTests {
    private final class StatementRecorder {
        private(set) var statements: [String] = []

        func record(_ sql: String) -> QueryResult {
            statements.append(sql)
            return .empty
        }
    }

    private struct Release {
        let databaseType: DatabaseType
        let banner: String?
        let listsWithShow: Bool
        let statusStatement: String
        let cancelStatement: String?
    }

    private static let currentSessionsQuery = """
        SELECT ID, USER, DB, COMMAND, TIME, STATE, LEFT(INFO, 1000) AS INFO
        FROM information_schema.PROCESSLIST
        WHERE ID <> CONNECTION_ID()
        ORDER BY TIME DESC
        """

    private static let currentSlowQueriesQuery = """
        SELECT ID, USER, DB, TIME, LEFT(INFO, 1000) AS INFO
        FROM information_schema.PROCESSLIST
        WHERE COMMAND <> 'Sleep' AND TIME > 1 AND ID <> CONNECTION_ID()
        ORDER BY TIME DESC
        """

    private static let legacyListing = ["SELECT CONNECTION_ID()", "SHOW FULL PROCESSLIST"]

    private static let releases = [
        Release(
            databaseType: .mysql, banner: "4.1.22-standard", listsWithShow: true,
            statusStatement: "SHOW STATUS", cancelStatement: nil
        ),
        Release(
            databaseType: .mysql, banner: "5.0.0", listsWithShow: true,
            statusStatement: "SHOW STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.0.2", listsWithShow: true,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.0.96", listsWithShow: true,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.1.6", listsWithShow: true,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.1.7", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.1.73", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "5.5.61", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mariadb, banner: "10.6.16-MariaDB", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mariadb, banner: "5.5.5-10.11.6-MariaDB", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: nil, listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        ),
        Release(
            databaseType: .mysql, banner: "unparsable", listsWithShow: false,
            statusStatement: "SHOW GLOBAL STATUS", cancelStatement: "KILL QUERY 52"
        )
    ]

    private static let processListColumns = ["Id", "User", "Host", "db", "Command", "Time", "State", "Info"]

    private static func result(columns: [String], rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows.map { row in row.map { $0.map { PluginCellValue.text($0) } ?? .null } },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    private static func legacyServer(_ sql: String) -> QueryResult {
        switch sql {
        case "SELECT CONNECTION_ID()":
            return result(columns: ["CONNECTION_ID()"], rows: [["245"]])
        case "SHOW FULL PROCESSLIST":
            return result(columns: processListColumns, rows: [
                ["245", "root", "172.17.0.1:59306", nil, "Query", "0", nil, "SHOW FULL PROCESSLIST"],
                ["13", "app", "10.0.0.3:5001", "shop", "Query", "7", "Sending data", "SELECT * FROM orders"],
                ["12", "app", "10.0.0.2:5000", "shop", "Sleep", "40", nil, nil],
                ["14", "report", "10.0.0.4:5002", nil, "Query", "1", "Locked", "UPDATE t SET a = 1"]
            ])
        default:
            return .empty
        }
    }

    private static func provider(_ databaseType: DatabaseType, banner: String?) throws -> any ServerDashboardQueryProvider {
        try #require(ServerDashboardQueryProviderFactory.provider(for: databaseType, serverVersion: banner))
    }

    @Test("Each server release is sent only the statements it can answer")
    func statementsFollowTheBanner() async throws {
        for release in Self.releases {
            let label = "\(release.databaseType.rawValue) \(release.banner ?? "nil")"
            let provider = try Self.provider(release.databaseType, banner: release.banner)

            let sessions = StatementRecorder()
            _ = try await provider.fetchSessions { sessions.record($0) }
            let metrics = StatementRecorder()
            _ = try await provider.fetchMetrics { metrics.record($0) }
            let slow = StatementRecorder()
            _ = try await provider.fetchSlowQueries { slow.record($0) }

            #expect(
                sessions.statements == (release.listsWithShow ? Self.legacyListing : [Self.currentSessionsQuery]),
                "\(label)"
            )
            #expect(
                slow.statements == (release.listsWithShow ? Self.legacyListing : [Self.currentSlowQueriesQuery]),
                "\(label)"
            )
            #expect(metrics.statements == [release.statusStatement, "SELECT @@max_connections"], "\(label)")
            #expect(provider.cancelQuerySQL(processId: "52") == release.cancelStatement, "\(label)")
            #expect(provider.killSessionSQL(processId: "52") == "KILL 52", "\(label)")
        }
    }

    @Test("Below 5.1.7 sessions come from SHOW FULL PROCESSLIST, longest first, without the dashboard's own")
    func legacySessionsAreFilteredAndSorted() async throws {
        let provider = try Self.provider(.mysql, banner: "4.1.22-standard")
        let sessions = try await provider.fetchSessions { Self.legacyServer($0) }

        #expect(sessions.map(\.id) == ["12", "13", "14"])
        let running = try #require(sessions.first { $0.id == "13" })
        #expect(running.user == "app")
        #expect(running.database == "shop")
        #expect(running.state == "Sending data")
        #expect(running.durationSeconds == 7)
        #expect(running.query == "SELECT * FROM orders")
    }

    @Test("Below 5.1.7 slow queries are the non-sleeping sessions running longer than a second")
    func legacySlowQueriesMatchTheCatalogFilter() async throws {
        let provider = try Self.provider(.mysql, banner: "5.0.96")
        let slow = try await provider.fetchSlowQueries { Self.legacyServer($0) }

        #expect(slow.map(\.query) == ["SELECT * FROM orders"])
        #expect(slow.first?.user == "app")
        #expect(slow.first?.database == "shop")
    }

    @Test("Below 5.1.7 the query text is cut to 1000 characters, as LEFT(INFO, 1000) does")
    func legacyQueryTextIsCut() async throws {
        let provider = try Self.provider(.mysql, banner: "5.1.6")
        let longQuery = "SELECT '" + String(repeating: "x", count: 1_500) + "'"
        let sessions = try await provider.fetchSessions { sql in
            sql == "SHOW FULL PROCESSLIST"
                ? Self.result(
                    columns: Self.processListColumns,
                    rows: [["7", "app", "10.0.0.2:5000", "shop", "Query", "3", "Sending data", longQuery]]
                )
                : .empty
        }

        let session = try #require(sessions.first)
        #expect(session.query == String(longQuery.prefix(1_000)))
    }

    @Test("MySQL before 5.0 cannot cancel a query alone, so the row offers only Terminate and MCP names kill")
    func legacyCancelIsRefused() throws {
        let provider = try Self.provider(.mysql, banner: "4.1.22-standard")
        let session = DashboardSession(
            id: "52", user: "app", database: "shop", state: "Sending data",
            durationSeconds: 3, duration: "3s", query: "SELECT 1"
        )
        #expect(!provider.canCancel(session))
        #expect(provider.canKill(session))

        do {
            _ = try MCPConnectionBridge.sessionControlStatement(provider: provider, processId: "52", cancelOnly: true)
            Issue.record("Cancel built a statement 4.1 refuses with 1204")
        } catch let error as DatabaseAccessError {
            let refusal = MCPToolExecutionError.from(error)
            #expect(refusal.code == .invalidArgument)
            #expect(refusal.message.contains("kill"))
        }
        #expect(
            try MCPConnectionBridge.sessionControlStatement(provider: provider, processId: "52", cancelOnly: false)
                == "KILL 52"
        )
    }
}
