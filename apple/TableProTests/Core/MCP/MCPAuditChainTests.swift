import Foundation
import SQLite3
import TableProPluginKit
import Testing

@testable import TablePro

struct MCPAuditChainTests {
    private static func makeStorage() -> (storage: MCPAuditLogStorage, path: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuditChainTests-\(UUID().uuidString)", isDirectory: true)
        let path = directory.appendingPathComponent(MCPAuditLogStorage.databaseFileName).path
        return (MCPAuditLogStorage(directory: directory), path)
    }

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
        let storage = Self.makeStorage().storage
        for index in 0..<5 {
            await storage.addEntry(entry(action: "tool.run\(index)"))
        }
        #expect(await storage.verify() == .intact(count: 5))
    }

    @Test("An empty log verifies intact")
    func emptyChainVerifiesIntact() async {
        let storage = Self.makeStorage().storage
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
        let storage = Self.makeStorage().storage
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
        let (storage, path) = Self.makeStorage()
        for index in 0..<3 {
            await storage.addEntry(entry(action: index == 1 ? marker : "tool.run\(index)"))
        }

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
        let (storage, path) = Self.makeStorage()
        for index in 0..<3 {
            await storage.addEntry(entry(action: index == 1 ? marker : "tool.gone\(index)"))
        }

        #expect(Self.execute("DELETE FROM audit_entries WHERE action = '\(marker)';", at: path))

        #expect(await storage.verify() == .broken(atSequence: 2))
    }

    @Test("A row reordered behind the app's back is detected")
    func reorderedRowIsDetected() async throws {
        let marker = "tool.reordered.\(UUID().uuidString)"
        let (storage, path) = Self.makeStorage()
        await storage.addEntry(entry(action: marker))
        await storage.addEntry(entry(action: "tool.second"))

        #expect(Self.execute("UPDATE audit_entries SET sequence = 9 WHERE sequence = 1;", at: path))

        #expect(await storage.verify() == .broken(atSequence: 9))
    }

    private static func execute(_ sql: String, at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
