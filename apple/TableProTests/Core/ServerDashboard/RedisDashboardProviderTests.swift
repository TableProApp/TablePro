//
//  RedisDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProRedisCore
import Testing

struct RedisDashboardProviderTests {
    private final class Server {
        private(set) var commands: [String] = []
        private let answer: (String) throws -> QueryResult

        init(_ answer: @escaping (String) throws -> QueryResult) {
            self.answer = answer
        }

        func execute(_ command: String) throws -> QueryResult {
            commands.append(command)
            return try answer(command)
        }
    }

    private struct Refusal: Error {}

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

    private static func cell(_ text: String) -> QueryResult {
        result(["result"], [[text]])
    }

    private static let listing = """
        id=15 addr=127.0.0.1:59686 laddr=127.0.0.1:6379 fd=16 name= age=1 idle=0 flags=N db=0 sub=0 psub=0 \
        multi=-1 cmd=client|list user=default redir=-1 resp=2
        id=21 addr=10.0.0.4:51022 laddr=127.0.0.1:6379 fd=17 name=worker age=900 idle=42 flags=b db=3 sub=0 \
        psub=0 multi=-1 cmd=blpop user=jobs redir=-1 resp=2
        id=22 addr=10.0.0.5:51023 laddr=127.0.0.1:6379 fd=18 name= age=10 idle=0 flags=N db=0 sub=0 psub=0 \
        multi=-1 cmd=get user=default redir=-1 resp=3

        """

    @Test("Clients come from CLIENT LIST without the dashboard's own connection")
    func sessionsLeaveOutTheDashboard() async throws {
        let server = Server { command in
            command.hasSuffix("CLIENT ID") ? Self.cell("15") : Self.cell(Self.listing)
        }
        let sessions = try await RedisDashboardProvider().fetchSessions { try server.execute($0) }
        #expect(sessions.map { $0.id } == ["21", "22"])
        #expect(server.commands == ["OUTSIDEBLOCK CLIENT ID", "OUTSIDEBLOCK CLIENT LIST"])

        let blocked = try #require(sessions.first)
        #expect(blocked.user == "jobs")
        #expect(blocked.database == "db3")
        #expect(blocked.state == "blocked")
        #expect(blocked.durationSeconds == 42)
        #expect(blocked.query == "blpop")
        #expect(blocked.canKill)
        #expect(blocked.canCancel)
        #expect(sessions.last?.state == "active")
        #expect(sessions.last?.canCancel == false)
    }

    @Test("A server without CLIENT ID still lists its clients")
    func sessionsWithoutClientId() async throws {
        let server = Server { command in
            if command.hasSuffix("CLIENT ID") { throw Refusal() }
            return Self.cell(Self.listing)
        }
        let sessions = try await RedisDashboardProvider().fetchSessions { try server.execute($0) }
        #expect(sessions.count == 3)
    }

    @Test("The state names the flag that sets a client apart", arguments: [
        ("b", 5, "blocked"),
        ("x", 0, "multi"),
        ("P", 30, "pubsub"),
        ("S", 0, "replica"),
        ("M", 0, "master"),
        ("N", 3, "idle"),
        ("N", 0, "active"),
    ] as [(String, Int, String)])
    func stateFollowsFlags(flags: String, idle: Int, state: String) {
        #expect(RedisDashboardProvider.state(flags: flags, idleSeconds: idle) == state)
    }

    @Test("Metrics read INFO fields by their whole name")
    func metricsReadInfo() async throws {
        let info = """
            # Server\r
            redis_version:8.10.2\r
            uptime_in_seconds:39738\r
            # Clients\r
            connected_clients:4\r
            # Memory\r
            used_memory_human:1.70M\r
            used_memory:1778512\r
            maxmemory:3557024\r
            # Stats\r
            instantaneous_ops_per_sec:3\r
            keyspace_hits:30\r
            keyspace_misses:10\r

            """
        let metrics = try await RedisDashboardProvider().fetchMetrics { _ in Self.result(["info"], [[info]]) }
        #expect(metrics.map { $0.id } == ["connected_clients", "used_memory", "operations", "keyspace_hit_ratio", "uptime"])
        #expect(metrics.first { $0.id == "used_memory" }?.value == ByteSizeFormatting.string(bytes: Int64(1_778_512)))
        #expect(metrics.first { $0.id == "used_memory" }?.unit.isEmpty == false)
        #expect(metrics.first { $0.id == "keyspace_hit_ratio" }?.value == "75.0")
        #expect(metrics.first { $0.id == "operations" }?.value == "3")
    }

    @Test("Memory with no limit set carries no share of one")
    func memoryWithoutLimit() async throws {
        let info = "used_memory:1024\r\nmaxmemory:0\r\n"
        let metrics = try await RedisDashboardProvider().fetchMetrics { _ in Self.result(["info"], [[info]]) }
        #expect(metrics.first { $0.id == "used_memory" }?.unit == "")
    }

    @Test("Slow log entries keep their sub-second durations and come newest first across nodes")
    func slowQueriesFromTheSlowLog() async throws {
        let rows: [[String?]] = [
            ["4", "1792537100", "626", #"SET foo "a b""#, "127.0.0.1:59713", ""],
            ["9", "1792537207", "12345", "KEYS *", "10.0.0.4:51022", "worker"],
        ]
        let server = Server { _ in Self.result(RedisSlowLogGrid.columns, rows) }
        let slow = try await RedisDashboardProvider().fetchSlowQueries { try server.execute($0) }
        #expect(server.commands == ["OUTSIDEBLOCK SLOWLOG GET 20"])
        #expect(slow.map { $0.query } == ["KEYS *", #"SET foo "a b""#])
        #expect(slow.first?.duration == DurationFormatting.string(microseconds: 12_345))
        #expect(slow.first?.user == "10.0.0.4:51022")
        #expect(slow.last?.duration == DurationFormatting.string(microseconds: 626))
    }

    @Test("Terminate is CLIENT KILL ID and Cancel is CLIENT UNBLOCK, for a numeric id only", arguments: [
        ("21", true),
        ("21 SKIPME no", false),
        ("-1", false),
        ("", false),
    ] as [(String, Bool)])
    func terminateAndCancelNameOneClient(processId: String, accepted: Bool) {
        let provider = RedisDashboardProvider()
        #expect(provider.killSessionSQL(processId: processId)
            == (accepted ? "OUTSIDEBLOCK CLIENT KILL ID \(processId)" : nil))
        #expect(provider.cancelQuerySQL(processId: processId)
            == (accepted ? "OUTSIDEBLOCK CLIENT UNBLOCK \(processId) ERROR" : nil))
    }

    @Test("Every command goes outside the user's MULTI block")
    func everyCommandIsHeldOutsideTheBlock() async throws {
        let server = Server { _ in .empty }
        let provider = RedisDashboardProvider()
        _ = try await provider.fetchSessions { try server.execute($0) }
        _ = try await provider.fetchMetrics { try server.execute($0) }
        _ = try await provider.fetchSlowQueries { try server.execute($0) }
        #expect(server.commands.count == 4)
        #expect(server.commands.allSatisfy { $0.hasPrefix("OUTSIDEBLOCK ") })
    }
}
