//
//  MCPAuditLogStorageTests.swift
//  TableProTests
//
//  The audit log is evidence, so it has to survive being read by the wrong person and being edited
//  by one. Every row carries the token id that caused it, so a token can be traced; the statement
//  is reduced to a digest, so a CREATE USER with an inline password never lands on disk in
//  cleartext; and the store and its journal files are owner-only.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Audit Log Storage", .serialized)
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
        let storage = makeStorage()
        await storage.addEntry(makeEntry(action: "tool.permissions"))

        let directory = Self.auditDirectory()
        let directoryPermissions = try #require(Self.permissions(ofItemAt: directory.path))
        #expect(directoryPermissions & 0o077 == 0)

        let paths = await storage.databaseFilePaths
        #expect(paths.isEmpty == false)
        for path in paths {
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

    @Test("No log statement in the MCP surface interpolates token material")
    func loggingNeverInterpolatesTokenMaterial() throws {
        let offenders = try Self.loggedInterpolations().filter { interpolation in
            Self.tokenMaterialNames.contains { interpolation.value.lowercased().contains($0) }
        }

        #expect(
            offenders.isEmpty,
            """
            A log line must never carry token material, not even a prefix or a digest of one: \
            \(offenders.map(\.description).sorted())
            """
        )
    }

    private static let tokenMaterialNames = [
        "fingerprint",
        "plaintext",
        "tokenhash",
        "salt",
        "verifier",
        "prefix",
        "password",
        "secret"
    ]

    private struct LoggedInterpolation {
        let file: String
        let line: Int
        let value: String

        var description: String { "\(file):\(line) \(value)" }
    }

    private static func loggedInterpolations() throws -> [LoggedInterpolation] {
        let root = try repositoryRoot().appendingPathComponent("TablePro/Core/MCP")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var found: [LoggedInterpolation] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (offset, line) in text.components(separatedBy: .newlines).enumerated()
                where line.contains("privacy:") {
                for value in interpolatedValues(in: line) {
                    found.append(
                        LoggedInterpolation(file: url.lastPathComponent, line: offset + 1, value: value)
                    )
                }
            }
        }
        return found
    }

    private static func interpolatedValues(in line: String) -> [String] {
        var values: [String] = []
        var remainder = Substring(line)
        while let start = remainder.range(of: "\\(") {
            let body = remainder[start.upperBound...]
            let end = body.firstIndex { $0 == "," || $0 == ")" } ?? body.endIndex
            values.append(String(body[body.startIndex..<end]))
            remainder = body[end...]
        }
        return values
    }

    private static func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func auditDirectory() -> URL {
        AppStorageEnvironment.shared.applicationSupportRoot.appendingPathComponent("TablePro")
    }

    private static func auditFileNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: auditDirectory().path)) ?? []
        let prefix = "mcp-audit-test_\(ProcessInfo.processInfo.processIdentifier)"
        return contents.filter { $0.hasPrefix(prefix) }
    }

    private static func permissions(ofItemAt path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
