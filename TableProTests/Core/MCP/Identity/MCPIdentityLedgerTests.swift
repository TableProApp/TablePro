//
//  MCPIdentityLedgerTests.swift
//  TableProTests
//
//  An approval belongs to the token that earned it and to the one connection it was given for, and
//  it expires on its own. There is no session to hang it on any more, so the ledger key is the
//  token id, or the principal's fingerprint when there is no token: two anonymous callers are two
//  callers.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Identity Ledgers")
struct MCPIdentityLedgerTests {
    private func principal(tokenId: UUID?, fingerprint: String = "fp") -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: fingerprint,
            tokenId: tokenId,
            scopes: MCPScope.readWriteSet,
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(label: "client", issuedAt: .distantPast, expiresAt: nil)
        )
    }

    @Test("An approval is scoped to the token that earned it")
    func approvalDoesNotLeakAcrossTokens() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let first = principal(tokenId: UUID(), fingerprint: "first")
        let second = principal(tokenId: UUID(), fingerprint: "second")

        await ledger.record(principal: first, connectionId: connectionId, approved: true)

        #expect(await ledger.isApproved(principal: first, connectionId: connectionId) == true)
        #expect(await ledger.isApproved(principal: second, connectionId: connectionId) == false)
    }

    @Test("An approval is scoped to the connection it was given for")
    func approvalDoesNotLeakAcrossConnections() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let approved = UUID()
        let other = UUID()
        let subject = principal(tokenId: UUID())

        await ledger.record(principal: subject, connectionId: approved, approved: true)

        #expect(await ledger.isApproved(principal: subject, connectionId: approved) == true)
        #expect(await ledger.isApproved(principal: subject, connectionId: other) == false)
        #expect(await ledger.approvedConnectionIds(principal: subject) == [approved])
    }

    @Test("An approval expires once its lifetime elapses")
    func approvalExpires() async {
        let clock = MCPTestClock()
        let ledger = MCPApprovalLedger(ttl: .seconds(60), clock: clock)
        let connectionId = UUID()
        let subject = principal(tokenId: UUID())

        await ledger.record(principal: subject, connectionId: connectionId, approved: true)
        await clock.advance(by: .seconds(59))
        #expect(await ledger.isApproved(principal: subject, connectionId: connectionId) == true)

        await clock.advance(by: .seconds(2))
        #expect(await ledger.isApproved(principal: subject, connectionId: connectionId) == false)
        #expect(await ledger.approvedConnectionIds(principal: subject).isEmpty)
    }

    @Test("The default approval lifetime is half an hour")
    func defaultApprovalLifetime() async {
        let clock = MCPTestClock()
        let ledger = MCPApprovalLedger(clock: clock)
        let connectionId = UUID()
        let subject = principal(tokenId: UUID())

        await ledger.record(principal: subject, connectionId: connectionId, approved: true)
        await clock.advance(by: .seconds(1_799))
        #expect(await ledger.isApproved(principal: subject, connectionId: connectionId) == true)

        await clock.advance(by: .seconds(2))
        #expect(await ledger.isApproved(principal: subject, connectionId: connectionId) == false)
    }

    @Test("Revoking a token drops only that token's approvals")
    func clearByTokenId() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let revokedId = UUID()
        let revoked = principal(tokenId: revokedId, fingerprint: "revoked")
        let survivor = principal(tokenId: UUID(), fingerprint: "survivor")

        await ledger.record(principal: revoked, connectionId: connectionId, approved: true)
        await ledger.record(principal: survivor, connectionId: connectionId, approved: true)
        await ledger.clear(tokenId: revokedId)

        #expect(await ledger.isApproved(principal: revoked, connectionId: connectionId) == false)
        #expect(await ledger.isApproved(principal: survivor, connectionId: connectionId) == true)
    }

    @Test("Clearing with no token id drops the anonymous approvals and leaves the issued ones")
    func clearWithoutTokenIdDropsAnonymousApprovals() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let anonymous = principal(tokenId: nil, fingerprint: MCPPrincipal.anonymousFingerprint)
        let issued = principal(tokenId: UUID(), fingerprint: "issued")

        await ledger.record(principal: anonymous, connectionId: connectionId, approved: true)
        await ledger.record(principal: issued, connectionId: connectionId, approved: true)
        await ledger.clear(tokenId: nil)

        #expect(await ledger.isApproved(principal: anonymous, connectionId: connectionId) == false)
        #expect(await ledger.isApproved(principal: issued, connectionId: connectionId) == true)
    }

    @Test("Two anonymous callers are two callers")
    func anonymousPrincipalsAreKeyedByFingerprint() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let first = principal(tokenId: nil, fingerprint: "first")
        let second = principal(tokenId: nil, fingerprint: "second")

        await ledger.record(principal: first, connectionId: connectionId, approved: true)

        #expect(first.ledgerKey == "anon:first")
        #expect(await ledger.isApproved(principal: first, connectionId: connectionId) == true)
        #expect(await ledger.isApproved(principal: second, connectionId: connectionId) == false)
    }

    @Test("A denial removes any standing approval")
    func denialRemovesApproval() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let subject = principal(tokenId: UUID())

        await ledger.record(principal: subject, connectionId: connectionId, approved: true)
        await ledger.record(principal: subject, connectionId: connectionId, approved: false)

        #expect(await ledger.isApproved(principal: subject, connectionId: connectionId) == false)
    }

    @Test("Clearing everything leaves no approval standing")
    func clearAllDropsEveryApproval() async {
        let ledger = MCPApprovalLedger(clock: MCPTestClock())
        let connectionId = UUID()
        let anonymous = principal(tokenId: nil, fingerprint: "anon")
        let issued = principal(tokenId: UUID())

        await ledger.record(principal: anonymous, connectionId: connectionId, approved: true)
        await ledger.record(principal: issued, connectionId: connectionId, approved: true)
        await ledger.clearAll()

        #expect(await ledger.isApproved(principal: anonymous, connectionId: connectionId) == false)
        #expect(await ledger.isApproved(principal: issued, connectionId: connectionId) == false)
    }

    private func meta(clientName: String, version: String) -> MCPRequestMeta {
        MCPRequestMeta(
            protocolVersion: .latest,
            clientInfo: MCPImplementation(name: clientName, version: version),
            clientCapabilities: .none,
            progressToken: nil
        )
    }

    @Test("Activity is folded onto one entry per client identity")
    func activityFoldsRepeatRequests() async {
        let ledger = MCPClientActivityLedger(idleTimeout: .seconds(300))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let subject = principal(tokenId: UUID())
        let requestMeta = meta(clientName: "Claude", version: "1.2.3")

        await ledger.record(meta: requestMeta, principal: subject, address: .loopback, at: start)
        await ledger.record(
            meta: requestMeta,
            principal: subject,
            address: .loopback,
            at: start.addingTimeInterval(30)
        )

        let entries = await ledger.snapshot(now: start.addingTimeInterval(30))
        #expect(entries.count == 1)
        #expect(entries.first?.clientName == "Claude")
        #expect(entries.first?.clientVersion == "1.2.3")
        #expect(entries.first?.tokenId == subject.tokenId)
        #expect(entries.first?.address == "127.0.0.1")
        #expect(entries.first?.firstSeenAt == start)
        #expect(entries.first?.lastSeenAt == start.addingTimeInterval(30))
    }

    @Test("An idle client falls out of the snapshot")
    func idleClientsArePruned() async {
        let ledger = MCPClientActivityLedger(idleTimeout: .seconds(60))
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        await ledger.record(
            meta: meta(clientName: "Claude", version: "1"),
            principal: principal(tokenId: UUID()),
            address: .loopback,
            at: start
        )

        #expect(await ledger.snapshot(now: start.addingTimeInterval(61)).isEmpty)
        #expect(await ledger.count(now: start.addingTimeInterval(61)) == 0)
    }

    @Test("Two tokens on one machine are two clients")
    func distinctTokensAreDistinctEntries() async {
        let ledger = MCPClientActivityLedger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let requestMeta = meta(clientName: "Claude", version: "1")

        await ledger.record(
            meta: requestMeta,
            principal: principal(tokenId: UUID(), fingerprint: "a"),
            address: .loopback,
            at: start
        )
        await ledger.record(
            meta: requestMeta,
            principal: principal(tokenId: UUID(), fingerprint: "b"),
            address: .loopback,
            at: start
        )

        #expect(await ledger.snapshot(now: start).count == 2)
    }

    @Test("A revoked token's activity is forgotten with it")
    func forgettingATokenDropsItsActivity() async {
        let ledger = MCPClientActivityLedger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let revokedId = UUID()

        await ledger.record(
            meta: meta(clientName: "Revoked", version: "1"),
            principal: principal(tokenId: revokedId, fingerprint: "a"),
            address: .loopback,
            at: start
        )
        await ledger.record(
            meta: meta(clientName: "Kept", version: "1"),
            principal: principal(tokenId: UUID(), fingerprint: "b"),
            address: .loopback,
            at: start
        )

        await ledger.forget(tokenId: revokedId)

        let entries = await ledger.snapshot(now: start)
        #expect(entries.map(\.clientName) == ["Kept"])
    }

    @Test("The activity list is capped and keeps the most recent clients")
    func activityListIsCapped() async {
        let ledger = MCPClientActivityLedger(idleTimeout: .seconds(3_600), maxEntries: 3)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<6 {
            await ledger.record(
                meta: meta(clientName: "Client \(index)", version: "1"),
                principal: principal(tokenId: UUID(), fingerprint: "fp\(index)"),
                address: .loopback,
                at: start.addingTimeInterval(Double(index))
            )
        }

        let entries = await ledger.snapshot(now: start.addingTimeInterval(6))
        #expect(entries.count == 3)
        #expect(entries.map(\.clientName) == ["Client 5", "Client 4", "Client 3"])
    }

    @Test("A client that sends no name is still listed under a readable one")
    func unnamedClientsGetAName() async {
        let ledger = MCPClientActivityLedger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let anonymousMeta = MCPRequestMeta(
            protocolVersion: .latest,
            clientInfo: nil,
            clientCapabilities: .none,
            progressToken: nil
        )

        await ledger.record(
            meta: anonymousMeta,
            principal: .anonymousLoopback,
            address: .loopback,
            at: start
        )

        let entry = await ledger.snapshot(now: start).first
        #expect(entry?.clientName == MCPClientIdentity.unknownClientName)
        #expect(entry?.tokenId == nil)
    }

    @Test("A client identity is a digest, not the token it presented")
    func clientIdentityIsADigest() {
        let identity = MCPClientIdentity(
            meta: meta(clientName: "Claude", version: "1"),
            principal: principal(tokenId: UUID(), fingerprint: "0123456789abcdef"),
            address: .loopback
        )

        let isHex = identity.id.allSatisfy { $0.isHexDigit }
        #expect(identity.id.count == 16)
        #expect(isHex)
        #expect(identity.id.contains("0123456789abcdef") == false)
        #expect(identity.addressDisplayValue == "127.0.0.1")
    }
}
