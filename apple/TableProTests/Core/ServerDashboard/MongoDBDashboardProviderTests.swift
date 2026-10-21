//
//  MongoDBDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MongoDBDashboardProviderTests {
    private static func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows.map { $0.map { PluginCellValue.fromOptional($0) } },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    private static let sessionColumns = ["active", "command", "connection", "ns", "opid", "secs", "user"]

    @Test("A running operation can be cancelled; an idle connection is listed by name and cannot")
    func sessionsMapOperationsAndIdleConnections() async throws {
        let rows: [[String?]] = [
            ["true", #"{"find": "orders", "filter": {"a": 1}}"#, "conn12", "shop.orders", "31745", "9", "app"],
            ["false", nil, "conn16", "", "", "", ""],
        ]
        let sessions = try await MongoDBDashboardProvider().fetchSessions { _ in
            Self.result(Self.sessionColumns, rows)
        }
        #expect(sessions.count == 2)

        let running = try #require(sessions.first)
        #expect(running.id == "31745")
        #expect(running.user == "app")
        #expect(running.database == "shop")
        #expect(running.state == "active")
        #expect(running.durationSeconds == 9)
        #expect(running.query.contains("orders"))
        #expect(running.canCancel)
        #expect(!running.canKill)

        let idle = try #require(sessions.last)
        #expect(idle.id == "conn16")
        #expect(idle.state == "idle")
        #expect(idle.duration.isEmpty)
        #expect(!idle.canCancel)
    }

    @Test("The sessions statement leaves out the dashboard's own operation and server threads")
    func sessionsStatementFiltersItself() {
        let statement = MongoDBDashboardProvider.sessionsStatement
        #expect(statement.contains(#""command.currentOp": { $exists: false }"#))
        #expect(statement.contains("client: { $exists: true }"))
        #expect(statement.contains("error.code !== 13"))
        #expect(statement.contains("request.$ownOps = true"))
        #expect(statement.contains(#"key !== "$truncated""#))
    }

    @Test("Every statement asks the server only through commands the driver lets a read run", arguments: [
        MongoDBDashboardProvider.sessionsStatement,
        MongoDBDashboardProvider.metricsStatement,
        MongoDBDashboardProvider.slowQueriesStatement,
    ])
    func statementsStayWithinReads(statement: String) {
        for call in ["aggregate", "runCommand", "killOp", "profile:", ".eval("] {
            #expect(!statement.contains(call), "\(call)")
        }
    }

    @Test("killOp is Cancel Query, and nothing ends a MongoDB connection")
    func cancelIsKillOp() {
        let provider = MongoDBDashboardProvider()
        #expect(provider.cancelQuerySQL(processId: "31745") == "db.adminCommand({ killOp: 1, op: 31745 })")
        #expect(provider.cancelQuerySQL(processId: "shard01:31745")
            == #"db.adminCommand({ killOp: 1, op: "shard01:31745" })"#)
        #expect(provider.killSessionSQL(processId: "31745") == nil)
    }

    @Test("Only an operation id reaches the shell", arguments: [
        ("31745", true),
        ("shard-01.rs_a:7", true),
        ("conn16", false),
        ("1}); db.dropDatabase(); ({", false),
        (#"shard":1"#, false),
        (":12", false),
        ("shard:", false),
        ("", false),
    ] as [(String, Bool)])
    func processIdIsAnOperationId(processId: String, accepted: Bool) {
        let provider = MongoDBDashboardProvider()
        #expect(provider.acceptsProcessId(processId) == accepted)
        #expect((provider.cancelQuerySQL(processId: processId) != nil) == accepted)
    }

    @Test("Metrics come from one serverStatus row")
    func metricsMapServerStatus() async throws {
        let columns = ["available", "command", "connections", "insert", "query", "remove", "resident", "update", "uptime"]
        let metrics = try await MongoDBDashboardProvider().fetchMetrics { _ in
            Self.result(columns, [["101548", "25", "5", "0", "3", "1", "136", "2", "225"]])
        }
        #expect(metrics.map { $0.id } == [
            "connections", "uptime", "resident_memory", "queries", "inserts", "updates", "deletes", "commands",
        ])
        #expect(metrics.first?.value == "5")
        #expect(metrics.first?.unit.contains("101548") == true)
        #expect(metrics.first { $0.id == "resident_memory" }?.value == ByteSizeFormatting.string(bytes: 136 * 1_048_576))
        #expect(metrics.first { $0.id == "deletes" }?.value == "1")
    }

    @Test("A profiled operation keeps its milliseconds instead of rounding to zero seconds")
    func slowQueriesMapProfilerEntries() async throws {
        let slow = try await MongoDBDashboardProvider().fetchSlowQueries { _ in
            Self.result(["command", "millis", "ns", "user"], [[#"{"find": "orders"}"#, "320", "shop.orders", "app@admin"]])
        }
        let entry = try #require(slow.first)
        #expect(entry.duration == DurationFormatting.string(microseconds: 320_000))
        #expect(entry.database == "shop")
        #expect(entry.user == "app@admin")
        #expect(entry.query.contains("orders"))
    }

    @Test("The database is the namespace before its first dot", arguments: [
        ("shop.orders", "shop"),
        ("admin.$cmd", "admin"),
        ("shop.system.profile", "shop"),
        ("", ""),
    ] as [(String, String)])
    func databaseOfNamespace(namespace: String, database: String) {
        #expect(MongoDBDashboardProvider.database(ofNamespace: namespace) == database)
    }
}
