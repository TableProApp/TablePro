//
//  RedisExactCountTests.swift
//  TableProTests
//
//  `Count Exactly` on a Redis database tab used to reach the kit's default, which answered nil, so
//  the estimate was never replaced. A filtered tab is now counted by the same MATCH glob and TYPE
//  scope its browse lists keys by, scanned to the end.
//

import Foundation
import TableProPluginKit
import Testing

/// Answers SCAN with the pages it was given, the way a cluster channel does when a node left the
/// topology mid-walk and it had to restart that node's cursor.
private final class PagedScanChannel: RedisCommandChannel, @unchecked Sendable {
    private var pages: [RedisKeyspacePage]

    init(_ pages: [RedisKeyspacePage]) {
        self.pages = pages
    }

    var isConnected: Bool { true }
    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {}
    func disconnect() {}
    func cancelCurrentQuery() {}
    func serverVersion() -> String? { "8.0.0" }
    func currentDatabase() -> Int { 0 }
    func reportedDatabaseCount() async throws -> Int? { 16 }
    func keyCountsByDatabase() async throws -> [Int: Int]? { nil }
    func executeCommand(_ args: [Data], scope: RedisCommandScope) async throws -> RedisReply { .null }
    func executePipeline(_ commands: [[Data]], scope: RedisCommandScope) async throws -> [RedisReply] { [] }
    func selectDatabase(_ index: Int, scope: RedisCommandScope) async throws {}

    func scanKeyspace(
        cursor: String,
        pattern: String?,
        type: String?,
        count: Int,
        scope: RedisCommandScope
    ) async throws -> RedisKeyspacePage {
        pages.removeFirst()
    }
}

struct RedisExactCountTests {
    @Test("A walk the cluster could not finish is refused rather than reported as exact")
    func incompleteWalkThrows() async {
        let channel = PagedScanChannel([
            RedisKeyspacePage(cursor: "node-b:0", keys: ["a", "b"], isIncomplete: false),
            RedisKeyspacePage(cursor: RedisClusterCursor.start, keys: ["c"], isIncomplete: true)
        ])

        await #expect(throws: RedisPluginError.self) {
            _ = try await channel.countKeys(pattern: nil, type: nil)
        }
    }

    @Test("The count walks the whole keyspace and counts a key SCAN returned twice once")
    func countsEveryPageOnce() async throws {
        let channel = StubRedisChannel([
            .array([.string("17"), .array([.string("user:1"), .string("user:2")])]),
            .array([.string("0"), .array([.string("user:2"), .string("user:3")])])
        ])

        let count = try await channel.countKeys(pattern: "user:*", type: "hash")

        #expect(count == 3)
        #expect(channel.sentCommands == [
            ["SCAN", "0", "MATCH", "user:*", "COUNT", "1000", "TYPE", "hash"],
            ["SCAN", "17", "MATCH", "user:*", "COUNT", "1000", "TYPE", "hash"]
        ])
    }

    @Test("The count reads the filters the way the browse does")
    func countScopeMatchesBrowse() throws {
        let builder = RedisQueryBuilder()
        let filters: [(column: String, op: String, value: String)] = [
            (column: "Key", op: "MATCH", value: "session:*"),
            (column: "Type", op: "=", value: "STRING")
        ]

        let scope = builder.browseScope(filters: filters)
        let browse = builder.buildFilteredQuery(namespace: "", database: 2, filters: filters)
        guard case .keyBrowse(let pattern, let typeScope, _, _, _) = try RedisCommandParser.parse(browse) else {
            Issue.record("Expected a keyBrowse operation for \(browse)")
            return
        }

        #expect(scope.pattern == pattern)
        #expect(scope.typeScope == typeScope)
        #expect(scope.pattern == "session:*")
        #expect(scope.typeScope == "string")
    }

    @Test("A filter the browse cannot narrow by leaves the count unfiltered too")
    func unnarrowingFilterCountsTheDatabase() {
        let scope = RedisQueryBuilder().browseScope(filters: [(column: "TTL", op: ">", value: "60")])
        #expect(scope.pattern == nil)
        #expect(scope.typeScope == nil)
    }
}
