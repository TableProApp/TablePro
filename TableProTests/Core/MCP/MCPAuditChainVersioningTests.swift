//
//  MCPAuditChainVersioningTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import Testing

/// The audit chain hashes an ordered field list, so adding a field to it reports every existing row
/// as tampered. These pin the versioning that stops that.
@Suite("MCP audit chain versioning")
struct MCPAuditChainVersioningTests {
    private func v1Entry(action: String = "tool.call") -> AuditEntry {
        AuditEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: .tool,
            tokenId: nil,
            tokenName: nil,
            connectionId: nil,
            action: action,
            outcome: AuditOutcome.success.rawValue,
            details: "ip=127.0.0.1"
        )
    }

    private func outbound() -> AuditOutboundDetail {
        AuditOutboundDetail(
            serverId: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            serverName: "docs",
            sessionId: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            target: "ext__x__search",
            payloadSHA256: String(repeating: "a", count: 64),
            payloadBytes: 128
        )
    }

    @Test("An entry with no outbound detail is version 1")
    func plainEntryIsV1() {
        #expect(v1Entry().schemaVersion == .v1)
        #expect(v1Entry().outbound == nil)
    }

    @Test("An entry carrying an outbound detail is version 2")
    func outboundEntryIsV2() {
        let entry = AuditEntry(
            category: .tool,
            action: "mcp.outbound.toolCall",
            outcome: AuditOutcome.success,
            outbound: outbound()
        )

        #expect(entry.schemaVersion == .v2)
    }

    @Test("The version 1 digest is unchanged by the version 2 fields existing")
    func v1DigestIsFrozen() {
        let entry = v1Entry()
        let expectedFields = [
            "7",
            entry.id.uuidString,
            String(entry.timestamp.timeIntervalSince1970),
            entry.category.rawValue,
            "",
            "",
            "",
            entry.action,
            entry.outcome,
            entry.details ?? "",
            "previous"
        ]
        let expected = SHA256.hash(
            data: Data(expectedFields.joined(separator: "\u{1F}").utf8)
        ).hexEncoded

        let digest = MCPAuditChainLink.digest(entry: entry, sequence: 7, previousHash: "previous")

        #expect(digest == expected)
    }

    @Test("A version 2 digest differs from the version 1 digest of the same base fields")
    func v2DigestCoversTheOutboundFields() {
        let base = v1Entry(action: "mcp.outbound.toolCall")
        let withOutbound = AuditEntry(
            id: base.id,
            timestamp: base.timestamp,
            category: base.category,
            tokenId: nil,
            tokenName: nil,
            connectionId: nil,
            action: base.action,
            outcome: base.outcome,
            details: base.details,
            schemaVersion: .v2,
            outbound: outbound()
        )

        let v1 = MCPAuditChainLink.digest(entry: base, sequence: 1, previousHash: "p")
        let v2 = MCPAuditChainLink.digest(entry: withOutbound, sequence: 1, previousHash: "p")

        #expect(v1 != v2)
    }

    @Test("Changing one outbound field changes the digest")
    func outboundFieldsAreCovered() {
        let detail = outbound()
        func entry(with outbound: AuditOutboundDetail) -> AuditEntry {
            AuditEntry(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
                timestamp: Date(timeIntervalSince1970: 1),
                category: .tool,
                tokenId: nil,
                tokenName: nil,
                connectionId: nil,
                action: "mcp.outbound.toolCall",
                outcome: AuditOutcome.success.rawValue,
                details: nil,
                schemaVersion: .v2,
                outbound: outbound
            )
        }
        let mutated = AuditOutboundDetail(
            serverId: detail.serverId,
            serverName: detail.serverName,
            sessionId: detail.sessionId,
            target: detail.target,
            payloadSHA256: detail.payloadSHA256,
            payloadBytes: detail.payloadBytes + 1
        )

        #expect(
            MCPAuditChainLink.digest(entry: entry(with: detail), sequence: 1, previousHash: "p")
                != MCPAuditChainLink.digest(entry: entry(with: mutated), sequence: 1, previousHash: "p")
        )
    }

    @Test("A v1 and a v2 row verify in one database")
    func mixedVersionsVerify() async {
        let storage = MCPAuditLogStorage(isolatedForTesting: true)

        #expect(await storage.addEntry(v1Entry()))
        #expect(await storage.addEntry(
            AuditEntry(
                category: .tool,
                action: "mcp.outbound.toolCall",
                outcome: AuditOutcome.success,
                outbound: outbound()
            )
        ))
        #expect(await storage.addEntry(v1Entry(action: "tool.call.second")))

        #expect(await storage.verify() == .intact(count: 3))
    }

    @Test("An outbound row round-trips its detail and stores no payload text")
    func outboundRowRoundTrips() async throws {
        let storage = MCPAuditLogStorage(isolatedForTesting: true)
        let detail = outbound()
        #expect(await storage.addEntry(
            AuditEntry(
                category: .tool,
                action: "mcp.outbound.toolCall",
                outcome: AuditOutcome.success,
                outbound: detail
            )
        ))

        let rows = await storage.query(limit: 10)
        let row = try #require(rows.first { $0.action == "mcp.outbound.toolCall" })

        #expect(row.outbound == detail)
        #expect(row.schemaVersion == .v2)
        #expect(row.details == nil)
    }
}
