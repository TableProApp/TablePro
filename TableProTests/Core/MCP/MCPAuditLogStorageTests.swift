//
//  MCPAuditLogStorageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Audit Log Storage")
struct MCPAuditLogStorageTests {
    private func makeStorage() -> MCPAuditLogStorage {
        MCPAuditLogStorage(isolatedForTesting: true)
    }

    private func makeEntry(
        category: AuditCategory = .tool,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        timestamp: Date = Date(),
        action: String = "tool.test",
        outcome: AuditOutcome = .success,
        details: String? = nil
    ) -> AuditEntry {
        AuditEntry(
            timestamp: timestamp,
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome,
            details: details
        )
    }

    @Test("Insert and read single entry")
    func insertAndRead() async {
        let storage = makeStorage()
        let entry = makeEntry(action: "auth.success", outcome: .success)
        let inserted = await storage.addEntry(entry)
        #expect(inserted == true)

        let entries = await storage.query()
        #expect(entries.count == 1)
        #expect(entries.first?.action == "auth.success")
        #expect(entries.first?.outcome == AuditOutcome.success.rawValue)
    }

    @Test("Query filters by category")
    func filterByCategory() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(category: .auth, action: "auth.success"))
        await storage.addEntry(makeEntry(category: .tool, action: "tool.run"))
        await storage.addEntry(makeEntry(category: .query, action: "query.executed"))

        let toolEntries = await storage.query(category: .tool)
        #expect(toolEntries.count == 1)
        #expect(toolEntries.first?.category == .tool)

        let authEntries = await storage.query(category: .auth)
        #expect(authEntries.count == 1)
        #expect(authEntries.first?.category == .auth)
    }

    @Test("Query filters by token")
    func filterByToken() async {
        let storage = makeStorage()
        let tokenA = UUID()
        let tokenB = UUID()
        await storage.addEntry(makeEntry(tokenId: tokenA, action: "tool.a"))
        await storage.addEntry(makeEntry(tokenId: tokenB, action: "tool.b"))
        await storage.addEntry(makeEntry(tokenId: tokenA, action: "tool.a2"))

        let aEntries = await storage.query(tokenId: tokenA)
        #expect(aEntries.count == 2)
        #expect(aEntries.allSatisfy { $0.tokenId == tokenA })

        let bEntries = await storage.query(tokenId: tokenB)
        #expect(bEntries.count == 1)
    }

    @Test("Query filters by since date")
    func filterBySince() async {
        let storage = makeStorage()
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3_600)
        let threeHoursAgo = now.addingTimeInterval(-3 * 3_600)

        await storage.addEntry(makeEntry(timestamp: threeHoursAgo, action: "old"))
        await storage.addEntry(makeEntry(timestamp: oneHourAgo, action: "recent"))
        await storage.addEntry(makeEntry(timestamp: now, action: "now"))

        let twoHoursAgo = now.addingTimeInterval(-2 * 3_600)
        let recent = await storage.query(since: twoHoursAgo)
        #expect(recent.count == 2)
        #expect(recent.allSatisfy { $0.timestamp >= twoHoursAgo })
    }

    @Test("Results sorted newest first")
    func sortedNewestFirst() async {
        let storage = makeStorage()
        let now = Date()
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-300), action: "older"))
        await storage.addEntry(makeEntry(timestamp: now, action: "newer"))

        let entries = await storage.query()
        #expect(entries.count == 2)
        #expect(entries[0].action == "newer")
        #expect(entries[1].action == "older")
    }

    @Test("Limit clamps result size")
    func limitClampsResultSize() async {
        let storage = makeStorage()
        for index in 0..<10 {
            await storage.addEntry(makeEntry(action: "tool.\(index)"))
        }

        let limited = await storage.query(limit: 3)
        #expect(limited.count == 3)
    }

    @Test("Prune removes entries older than the cutoff")
    func pruneRemovesOldEntries() async {
        let storage = makeStorage()
        let now = Date()
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-100 * 86_400), action: "ancient"))
        await storage.addEntry(makeEntry(timestamp: now, action: "fresh"))

        let removed = await storage.prune(olderThan: 90)
        #expect(removed == 1)

        let remaining = await storage.query()
        #expect(remaining.count == 1)
        #expect(remaining.first?.action == "fresh")
    }

    @Test("Prune with negative or zero days is a no-op")
    func pruneNoOpForZeroDays() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(action: "fresh"))

        let removed = await storage.prune(olderThan: 0)
        #expect(removed == 0)

        let entries = await storage.query()
        #expect(entries.count == 1)
    }

    @Test("Concurrent writes preserve all entries")
    func concurrentWrites() async {
        let storage = makeStorage()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await storage.addEntry(
                        AuditEntry(
                            timestamp: Date(),
                            category: .tool,
                            action: "tool.\(index)",
                            outcome: AuditOutcome.success.rawValue
                        )
                    )
                }
            }
        }

        let count = await storage.count()
        #expect(count == 50)
    }

    @Test("Outcome convenience initializer stores raw value")
    func outcomeInitializerStoresRawValue() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(outcome: .denied))

        let entries = await storage.query()
        #expect(entries.first?.outcome == AuditOutcome.denied.rawValue)
    }

    @Test("Insert with same id replaces previous entry")
    func insertOrReplacePreservesUniqueness() async {
        let storage = makeStorage()
        let id = UUID()
        let first = AuditEntry(
            id: id,
            timestamp: Date(),
            category: .tool,
            action: "first",
            outcome: AuditOutcome.success
        )
        let second = AuditEntry(
            id: id,
            timestamp: Date(),
            category: .tool,
            action: "second",
            outcome: AuditOutcome.success
        )
        await storage.addEntry(first)
        await storage.addEntry(second)

        let entries = await storage.query()
        #expect(entries.count == 1)
        #expect(entries.first?.action == "second")
    }
}
