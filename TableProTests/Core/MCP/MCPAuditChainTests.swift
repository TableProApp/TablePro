//
//  MCPAuditChainTests.swift
//  TableProTests
//
//  Every row hashes its own fields, its sequence number and the hash before it, so the log is only
//  evidence while that chain holds. Editing a row, reordering two rows and deleting one all break
//  it, and `verify()` names the sequence where the break starts.
//

import Foundation
import SQLite3
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Audit Chain")
struct MCPAuditChainTests {
    private func entry(action: String, details: String? = nil) -> AuditEntry {
        AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: .tool,
            tokenId: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            tokenName: "client",
            connectionId: nil,
            action: action,
            outcome: AuditOutcome.success,
            details: details
        )
    }

    @Test("An appended log verifies intact")
    func chainVerifiesIntact() async {
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        for index in 0..<5 {
            await storage.addEntry(entry(action: "tool.run\(index)"))
        }
        #expect(await storage.verify() == .intact(count: 5))
    }

    @Test("An empty log verifies intact")
    func emptyChainVerifiesIntact() async {
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        #expect(await storage.verify() == .intact(count: 0))
    }

    @Test("Changing one field changes the entry digest")
    func digestCoversEveryField() {
        let base = entry(action: "tool.run", details: "sqlDigest=abc")
        let edited = AuditEntry(
            id: base.id,
            timestamp: base.timestamp,
            category: base.category,
            tokenId: base.tokenId,
            tokenName: base.tokenName,
            connectionId: base.connectionId,
            action: base.action,
            outcome: base.outcome,
            details: "sqlDigest=def"
        )

        let previous = MCPAuditChainLink.genesisHash
        #expect(
            MCPAuditChainLink.digest(entry: base, sequence: 0, previousHash: previous)
                != MCPAuditChainLink.digest(entry: edited, sequence: 0, previousHash: previous)
        )
    }

    @Test("Reordering two entries breaks the chain")
    func reorderingBreaksTheChain() {
        let first = entry(action: "tool.first")
        let second = entry(action: "tool.second")

        let firstHash = MCPAuditChainLink.digest(
            entry: first,
            sequence: 0,
            previousHash: MCPAuditChainLink.genesisHash
        )
        let secondHash = MCPAuditChainLink.digest(entry: second, sequence: 1, previousHash: firstHash)
        let swappedSecondHash = MCPAuditChainLink.digest(
            entry: second,
            sequence: 0,
            previousHash: MCPAuditChainLink.genesisHash
        )

        #expect(secondHash != swappedSecondHash)
    }

    @Test("Clearing the log restarts the chain at genesis")
    func deleteAllResetsTheChain() async {
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        await storage.addEntry(entry(action: "tool.first"))
        #expect(await storage.deleteAll() == true)
        await storage.addEntry(entry(action: "tool.second"))
        #expect(await storage.verify() == .intact(count: 1))
    }

    @Test("An executed statement is stored as a digest, never as text")
    func statementIsStoredAsDigest() {
        let sql = "CREATE USER analyst WITH PASSWORD 'hunter2'"
        let digest = MCPAuditLogger.statementDigest(sql)
        #expect(digest.count == 64)
        #expect(!digest.contains("hunter2"))
        #expect(digest == MCPAuditLogger.statementDigest(sql))
        #expect(digest != MCPAuditLogger.statementDigest(sql + " "))
    }

    @Test("A row edited behind the app's back is detected")
    func editedRowIsDetected() async throws {
        let marker = "tool.edited.\(UUID().uuidString)"
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        for index in 0..<3 {
            await storage.addEntry(entry(action: index == 1 ? marker : "tool.run\(index)"))
        }
        let path = try #require(Self.databasePath(containing: marker))

        #expect(
            Self.execute(
                "UPDATE audit_entries SET details = 'edited' WHERE action = '\(marker)';",
                at: path
            )
        )

        #expect(await storage.verify() == .broken(atSequence: 1))
    }

    @Test("A row removed behind the app's back is detected")
    func removedRowIsDetected() async throws {
        let marker = "tool.removed.\(UUID().uuidString)"
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        for index in 0..<3 {
            await storage.addEntry(entry(action: index == 1 ? marker : "tool.gone\(index)"))
        }
        let path = try #require(Self.databasePath(containing: marker))

        #expect(Self.execute("DELETE FROM audit_entries WHERE action = '\(marker)';", at: path))

        #expect(await storage.verify() == .broken(atSequence: 2))
    }

    @Test("A row reordered behind the app's back is detected")
    func reorderedRowIsDetected() async throws {
        let marker = "tool.reordered.\(UUID().uuidString)"
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        await storage.addEntry(entry(action: marker))
        await storage.addEntry(entry(action: "tool.second"))
        let path = try #require(Self.databasePath(containing: marker))

        #expect(Self.execute("UPDATE audit_entries SET sequence = 9 WHERE sequence = 1;", at: path))

        #expect(await storage.verify() == .broken(atSequence: 9))
    }

    private static func databasePath(containing action: String) -> String? {
        let directory = AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
        let prefix = "mcp-audit-test_\(ProcessInfo.processInfo.processIdentifier)"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".db") }
        return names
            .map { directory.appendingPathComponent($0).path }
            .first { contains(action: action, at: $0) }
    }

    private static func contains(action: String, at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM audit_entries WHERE action = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, action, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    }

    private static func execute(_ sql: String, at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
