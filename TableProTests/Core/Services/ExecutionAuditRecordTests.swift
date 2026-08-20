//
//  ExecutionAuditRecordTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ExecutionAuditRecord")
struct ExecutionAuditRecordTests {
    private func chain(_ count: Int) -> [ExecutionAuditRecord] {
        var records: [ExecutionAuditRecord] = []
        for index in 0 ..< count {
            records.append(ExecutionAuditRecord(
                sequence: index,
                recordedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                connectionId: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)") ?? UUID(),
                kind: "writeQuery",
                caller: "userInterface",
                outcome: index.isMultiple(of: 2) ? .authorized : .denied,
                effectiveWrite: index.isMultiple(of: 2),
                statementDigest: ExecutionAuditRecord.sha256("select \(index)"),
                previousHash: records.last?.hash ?? ExecutionAuditRecord.genesisHash
            ))
        }
        return records
    }

    @Test("an untouched chain verifies")
    func intactChain() {
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: chain(5)) == nil)
    }

    @Test("an empty log verifies")
    func emptyChain() {
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: []) == nil)
    }

    @Test("editing a field in the middle is detected at that record")
    func editedRecordIsDetected() {
        var records = chain(5)
        let original = records[2]
        records[2] = ExecutionAuditRecord(
            sequence: original.sequence,
            recordedAt: original.recordedAt,
            connectionId: original.connectionId,
            kind: "metadataRead",
            caller: original.caller,
            outcome: original.outcome,
            effectiveWrite: original.effectiveWrite,
            statementDigest: original.statementDigest,
            previousHash: original.previousHash
        )
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: records) == 3)
    }

    @Test("flipping a denial to an authorization is detected")
    func flippedOutcomeIsDetected() {
        var records = chain(3)
        let original = records[1]
        records[1] = ExecutionAuditRecord(
            sequence: original.sequence,
            recordedAt: original.recordedAt,
            connectionId: original.connectionId,
            kind: original.kind,
            caller: original.caller,
            outcome: .authorized,
            effectiveWrite: original.effectiveWrite,
            statementDigest: original.statementDigest,
            previousHash: original.previousHash
        )
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: records) != nil)
    }

    @Test("deleting a record from the middle is detected")
    func deletedRecordIsDetected() {
        var records = chain(5)
        records.remove(at: 2)
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: records) == 3)
    }

    @Test("reordering two records is detected")
    func reorderedRecordsAreDetected() {
        var records = chain(4)
        records.swapAt(1, 2)
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: records) != nil)
    }

    @Test("truncating the tail is not detected, which is the honest limit of a local chain")
    func truncationIsNotDetected() {
        let records = Array(chain(5).prefix(3))
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: records) == nil)
    }

    @Test("two records differing only in where a field boundary falls hash differently")
    func fieldBoundariesCannotCollide() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ExecutionAuditRecord.digest(
            sequence: 1, recordedAt: date, connectionId: id, kind: "ab", caller: "userInterface", outcome: .authorized,
            effectiveWrite: true, statementDigest: "c", previousHash: ExecutionAuditRecord.genesisHash
        )
        let second = ExecutionAuditRecord.digest(
            sequence: 1, recordedAt: date, connectionId: id, kind: "a", caller: "userInterface", outcome: .authorized,
            effectiveWrite: true, statementDigest: "bc", previousHash: ExecutionAuditRecord.genesisHash
        )
        #expect(first != second)
    }

    @Test("the statement is stored as a digest, never as text")
    func statementIsHashed() {
        let sql = "SELECT * FROM customers WHERE email = 'a@example.com'"
        let digest = ExecutionAuditRecord.sha256(sql)
        #expect(digest.count == 64)
        #expect(digest.contains("example.com") == false)
        #expect(ExecutionAuditRecord.sha256(sql) == digest)
        #expect(ExecutionAuditRecord.sha256(sql + " ") != digest)
    }
}

@Suite("ExecutionAuditLog")
struct ExecutionAuditLogTests {
    private func makeLog() -> ExecutionAuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).json")
        return ExecutionAuditLog(fileURL: url)
    }

    private func request(write: Bool) -> OperationRequest {
        OperationRequest(
            connectionId: UUID(),
            databaseType: .postgresql,
            sql: write ? "UPDATE t SET a = 1" : "SELECT 1",
            kind: write ? .writeQuery : .metadataRead,
            caller: write ? .userInterface : .mcpClient(label: "test"),
            capabilities: [],
            operationDescription: "test"
        )
    }

    @Test("an authorization and a denial are both recorded, in order")
    func recordsBothOutcomes() async {
        let log = makeLog()
        let receipt = OperationReceipt(
            connectionId: UUID(), kind: .writeQuery, effectiveWrite: true, grantedAt: Date(), token: UUID()
        )
        await log.record(request: request(write: true), decision: .authorized(receipt))
        await log.record(request: request(write: false), decision: .denied(reason: "nope"))

        let entries = await log.entries()
        #expect(entries.count == 2)
        #expect(entries[0].outcome == .authorized)
        #expect(entries[1].outcome == .denied)
        #expect(entries[0].sequence == 0)
        #expect(entries[1].sequence == 1)
        #expect(entries[1].previousHash == entries[0].hash)
    }

    @Test("a fresh log verifies, and stays verifying as records are added")
    func staysIntact() async {
        let log = makeLog()
        #expect(await log.verify() == .intact(count: 0))
        for _ in 0 ..< 5 {
            await log.record(request: request(write: true), decision: .denied(reason: "denied"))
        }
        #expect(await log.verify() == .intact(count: 5))
    }

    @Test("a denial records no write, whatever the request asked for")
    func denialIsNeverAWrite() async {
        let log = makeLog()
        await log.record(request: request(write: true), decision: .denied(reason: "blocked"))
        let entries = await log.entries()
        #expect(entries[0].effectiveWrite == false)
    }

    @Test("concurrent decisions produce a chain with no repeated position")
    func concurrentWritesDoNotCollide() async {
        let log = makeLog()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask { await log.record(request: self.request(write: false), decision: .denied(reason: "x")) }
            }
        }
        let entries = await log.entries()
        #expect(entries.count == 20)
        #expect(Set(entries.map(\.sequence)).count == 20)
        #expect(await log.verify() == .intact(count: 20))
    }

    @Test("the default log lives inside the storage environment, so a UI test cannot append to the real chain")
    func defaultLocationFollowsStorageEnvironment() {
        let url = ExecutionAuditLog.defaultFileURL()
        #expect(url.lastPathComponent == "ExecutionAudit.json")
        #expect(url.deletingLastPathComponent() == AppStorageEnvironment.shared.supportDirectory)
        #expect(url.path.hasPrefix(AppStorageEnvironment.shared.applicationSupportRoot.path))
    }
}
