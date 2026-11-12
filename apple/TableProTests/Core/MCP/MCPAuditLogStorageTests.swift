import Foundation
import TableProMCP
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Audit Log Storage", .serialized)
struct MCPAuditLogStorageTests {
    private func makeStorage() -> MCPAuditLogStorage {
        MCPAuditLogStorage(directory: Self.makeDirectory())
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPAuditLogStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeEntry(
        category: AuditCategory = .tool,
        tokenId: UUID = UUID(),
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

    private func makePrincipal(tokenId: UUID, label: String) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "fp",
            tokenId: tokenId,
            scopes: MCPScope.readWriteSet,
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(label: label, issuedAt: .distantPast, expiresAt: nil)
        )
    }

    @Test("An appended row reads back")
    func insertAndRead() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(action: "auth.success", outcome: .success))

        let entries = await storage.query()

        #expect(entries.count == 1)
        #expect(entries.first?.action == "auth.success")
        #expect(entries.first?.outcome == AuditOutcome.success.rawValue)
    }

    @Test("The log filters by category")
    func filterByCategory() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(category: .auth, action: "auth.success"))
        await storage.addEntry(makeEntry(category: .tool, action: "tool.run"))
        await storage.addEntry(makeEntry(category: .query, action: "query.executed"))

        #expect(await storage.query(category: .tool).count == 1)
        #expect(await storage.query(category: .auth).first?.category == .auth)
    }

    @Test("The log filters by the token that caused the row")
    func filterByToken() async {
        let storage = makeStorage()
        let tokenA = UUID()
        let tokenB = UUID()
        await storage.addEntry(makeEntry(tokenId: tokenA, action: "tool.a"))
        await storage.addEntry(makeEntry(tokenId: tokenB, action: "tool.b"))
        await storage.addEntry(makeEntry(tokenId: tokenA, action: "tool.a2"))

        let forA = await storage.query(tokenId: tokenA)

        #expect(forA.count == 2)
        #expect(forA.allSatisfy { $0.tokenId == tokenA })
        #expect(await storage.query(tokenId: tokenB).count == 1)
    }

    @Test("The log filters by date")
    func filterBySince() async {
        let storage = makeStorage()
        let now = Date()
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-3 * 3_600), action: "old"))
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-3_600), action: "recent"))
        await storage.addEntry(makeEntry(timestamp: now, action: "now"))

        let cutoff = now.addingTimeInterval(-2 * 3_600)
        let recent = await storage.query(since: cutoff)

        #expect(recent.count == 2)
        #expect(recent.allSatisfy { $0.timestamp >= cutoff })
    }

    @Test("Rows come back newest first and honour the limit")
    func sortingAndLimit() async {
        let storage = makeStorage()
        let now = Date()
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-300), action: "older"))
        await storage.addEntry(makeEntry(timestamp: now, action: "newer"))
        for index in 0..<5 {
            await storage.addEntry(
                makeEntry(timestamp: now.addingTimeInterval(-600 - Double(index)), action: "bulk.\(index)")
            )
        }

        let entries = await storage.query()

        #expect(entries.first?.action == "newer")
        #expect(await storage.query(limit: 3).count == 3)
    }

    @Test("Pruning drops rows past the retention window and nothing else")
    func pruneRemovesOldEntries() async {
        let storage = makeStorage()
        let now = Date()
        await storage.addEntry(makeEntry(timestamp: now.addingTimeInterval(-100 * 86_400), action: "ancient"))
        await storage.addEntry(makeEntry(timestamp: now, action: "fresh"))

        #expect(await storage.prune(olderThan: 90) == 1)
        #expect(await storage.query().map(\.action) == ["fresh"])
        #expect(await storage.prune(olderThan: 0) == 0)
    }

    @Test("Concurrent writes all land")
    func concurrentWrites() async {
        let storage = makeStorage()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await storage.addEntry(
                        AuditEntry(category: .tool, action: "tool.\(index)", outcome: AuditOutcome.success)
                    )
                }
            }
        }

        #expect(await storage.count() == 50)
    }

    @Test("A row whose id is already in the log is refused, never overwritten")
    func duplicateIdIsRefused() async {
        let storage = makeStorage()
        let id = UUID()
        let first = AuditEntry(id: id, category: .tool, action: "first", outcome: AuditOutcome.success)
        let second = AuditEntry(id: id, category: .tool, action: "second", outcome: AuditOutcome.success)

        #expect(await storage.addEntry(first))
        #expect(await storage.addEntry(second) == false)

        let entries = await storage.query()
        #expect(entries.count == 1)
        #expect(entries.first?.action == "first")
        #expect(await storage.verify() == .intact(count: 1))
    }

    @Test("An outcome is stored by its raw value")
    func outcomeStoresRawValue() async {
        let storage = makeStorage()
        await storage.addEntry(makeEntry(outcome: .denied))

        #expect(await storage.query().first?.outcome == AuditOutcome.denied.rawValue)
    }

    @Test("The store and its journal files stay readable by their owner alone")
    func databaseFilesAreNotWorldReadable() async throws {
        let directory = Self.makeDirectory()
        let storage = MCPAuditLogStorage(directory: directory)
        await storage.addEntry(makeEntry(action: "tool.permissions"))

        let directoryPermissions = try #require(Self.permissions(ofItemAt: directory.path))
        #expect(directoryPermissions & 0o077 == 0)

        let databasePath = directory.appendingPathComponent(MCPAuditLogStorage.databaseFileName).path
        #expect(FileManager.default.fileExists(atPath: databasePath))
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] {
            guard let permissions = Self.permissions(ofItemAt: path) else { continue }
            #expect(
                permissions & 0o077 == 0,
                "\((path as NSString).lastPathComponent) is readable outside its owner"
            )
        }
        withExtendedLifetime(storage) {}
    }

    @Test("An executed statement reaches the log as a digest, never as text")
    func executedStatementIsStoredAsADigest() async throws {
        let tokenId = UUID()
        let sql = "CREATE USER analyst WITH PASSWORD 'hunter2'"

        MCPAuditLogger.logQueryExecuted(
            principal: makePrincipal(tokenId: tokenId, label: "client"),
            connectionId: UUID(),
            sql: sql,
            durationMs: 4,
            rowCount: 0,
            outcome: .success
        )
        await MCPAuditLogger.flush()

        let rows = await MCPAuditLogStorage.shared.query(tokenId: tokenId)
        let row = try #require(rows.first(where: { $0.action == "query.executed" }))
        let details = try #require(row.details)
        #expect(details.contains(MCPAuditLogger.statementDigest(sql)))
        #expect(details.contains("hunter2") == false)
        #expect(details.contains("CREATE USER") == false)
        #expect(row.tokenId == tokenId)
    }

    @Test("Administrative rows carry the token they are about, so the log can be filtered by it")
    func administrativeRowsCarryTheTokenId() async throws {
        let tokenId = UUID()

        MCPAuditLogger.logTokenCreated(tokenId: tokenId, tokenName: "paired client")
        MCPAuditLogger.logTokenRevoked(tokenId: tokenId, tokenName: "paired client")
        await MCPAuditLogger.flush()

        let rows = await MCPAuditLogStorage.shared.query(tokenId: tokenId)
        let actions = Set(rows.map(\.action))

        #expect(actions.contains("token.created"))
        #expect(actions.contains("token.revoked"))
        #expect(rows.allSatisfy { $0.tokenId == tokenId })
        #expect(rows.allSatisfy { $0.category == .admin })
    }

    @Test("A tool call is attributed to the token that made it")
    func toolCallsCarryTheTokenId() async throws {
        let tokenId = UUID()
        let connectionId = UUID()

        MCPAuditLogger.logToolCalled(
            principal: makePrincipal(tokenId: tokenId, label: "client"),
            toolName: "list_tables",
            connectionId: connectionId,
            outcome: .denied
        )
        await MCPAuditLogger.flush()

        let row = try #require(await MCPAuditLogStorage.shared.query(tokenId: tokenId).first)

        #expect(row.action == "tool.list_tables")
        #expect(row.connectionId == connectionId)
        #expect(row.outcome == AuditOutcome.denied.rawValue)
        #expect(row.tokenName == "client")
    }

    @Test("A damaged log is kept beside a fresh one, which starts by recording the reset")
    func damagedLogIsSetAsideAndAFreshOneStarts() async throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent(MCPAuditLogStorage.databaseFileName)
        let damaged = Data(repeating: 0x2A, count: 4_096)
        try damaged.write(to: databaseURL)

        let storage = MCPAuditLogStorage(directory: directory)
        #expect(await storage.addEntry(makeEntry(action: "tool.afterReset")))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let copyName = try #require(names.first { $0.hasPrefix("mcp-audit.damaged-") && $0.hasSuffix(".db") })
        let copyURL = directory.appendingPathComponent(copyName)
        #expect(try Data(contentsOf: copyURL) == damaged)
        let copyPermissions = try #require(Self.permissions(ofItemAt: copyURL.path))
        #expect(copyPermissions & 0o077 == 0)
        let freshPermissions = try #require(Self.permissions(ofItemAt: databaseURL.path))
        #expect(freshPermissions & 0o077 == 0)

        let entries = await storage.query()
        let actions = Set(entries.map { $0.action })
        #expect(actions == ["auditLog.setAside", "tool.afterReset"])
        let notice = try #require(entries.first { $0.action == "auditLog.setAside" })
        #expect(notice.details == "setAside=\(copyName)")
        #expect(await storage.verify() == .intact(count: 2))
    }

    @Test("The first entry after the log is reopened continues its chain")
    func reopenedLogContinuesItsChain() async {
        let directory = Self.makeDirectory()
        do {
            let first = MCPAuditLogStorage(directory: directory)
            #expect(await first.addEntry(makeEntry(action: "tool.beforeRelaunch")))
            #expect(await first.addEntry(makeEntry(action: "tool.beforeRelaunch2")))
        }

        let reopened = MCPAuditLogStorage(directory: directory)
        #expect(await reopened.addEntry(makeEntry(action: "tool.afterRelaunch")))
        #expect(await reopened.count() == 3)
        #expect(await reopened.verify() == .intact(count: 3))
    }

    @Test("The shared log writes the storage folder's mcp-audit.db, under a test host as in the app")
    func sharedLogUsesTheStorageFolder() async throws {
        MCPAuditLogger.logTokenCreated(tokenId: UUID(), tokenName: "paired client")
        await MCPAuditLogger.flush()

        let directory = AppStorageEnvironment.shared.supportDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains(MCPAuditLogStorage.databaseFileName))
        #expect(names.allSatisfy { !$0.hasPrefix("mcp-audit-test_") })
    }

    private static func permissions(ofItemAt path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
