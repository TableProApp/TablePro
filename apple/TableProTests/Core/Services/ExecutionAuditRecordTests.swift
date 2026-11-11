//
//  ExecutionAuditRecordTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

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

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).json")
    }

    private func storedChain(_ count: Int, startingAt first: Int = 0, after previous: String? = nil) -> [ExecutionAuditRecord] {
        var records: [ExecutionAuditRecord] = []
        for index in first ..< first + count {
            records.append(ExecutionAuditRecord(
                sequence: index,
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                connectionId: UUID(),
                kind: "readQuery",
                caller: "userInterface",
                outcome: .authorized,
                effectiveWrite: false,
                statementDigest: ExecutionAuditRecord.sha256("select \(index)"),
                previousHash: records.last?.hash ?? previous ?? ExecutionAuditRecord.genesisHash
            ))
        }
        return records
    }

    private func decodedArray(at url: URL) throws -> [ExecutionAuditRecord] {
        try JSONDecoder().decode([ExecutionAuditRecord].self, from: Data(contentsOf: url))
    }

    @Test("a log an earlier build wrote as one array goes on from its last record")
    func continuesAnEarlierBuildsArray() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier = storedChain(3)
        try JSONEncoder().encode(earlier).write(to: url)

        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let entries = await log.entries()
        #expect(entries.count == 4)
        #expect(entries[3].sequence == 3)
        #expect(entries[3].previousHash == earlier[2].hash)
        #expect(await log.verify() == .intact(count: 4))
    }

    @Test("after appends the file is still the array an earlier build decodes and rewrites")
    func fileStaysAnArray() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ExecutionAuditLog(fileURL: url)
        for _ in 0 ..< 3 {
            await log.record(request: request(write: false), decision: .denied(reason: "x"))
        }

        let decoded = try decodedArray(at: url)
        #expect(decoded.count == 3)
        #expect(ExecutionAuditRecord.firstBrokenSequence(in: decoded) == nil)
    }

    @Test("a log longer than the tail that is read on launch still chains from its last record")
    func longLogChainsFromItsTail() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier = storedChain(400)
        let data = try JSONEncoder().encode(earlier)
        #expect(data.count > 65_536)
        try data.write(to: url)

        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: true), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded.count == 401)
        #expect(decoded[400].previousHash == earlier[399].hash)
        #expect(await log.verify() == .intact(count: 401))
    }

    @Test("an empty array, padded with whitespace, takes its first record")
    func paddedEmptyArrayStartsTheChain() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[ ]\n".utf8).write(to: url)

        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        #expect(try decodedArray(at: url).count == 2)
        #expect(await log.verify() == .intact(count: 2))
    }

    @Test("a file changed by someone else is read again before the next record goes on")
    func externalChangeIsReadBeforeAppending() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let replaced = storedChain(5)
        try JSONEncoder().encode(replaced).write(to: url, options: .atomic)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let entries = await log.entries()
        #expect(entries.count == 6)
        #expect(entries[5].sequence == 5)
        #expect(entries[5].previousHash == replaced[4].hash)
    }

    @Test("an unreadable log is set aside with its bytes intact and a new chain starts")
    func unreadableLogIsSetAsideNotOverwritten() async throws {
        let url = temporaryURL()
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: url)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasPrefix("\(stem).damaged-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        let damaged = Data(#"[{"sequence":0,"recordedAt":1,"#.utf8)
        try damaged.write(to: url)

        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let setAside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(stem).damaged-") }
        #expect(setAside.count == 1)
        let kept = try Data(contentsOf: directory.appendingPathComponent(try #require(setAside.first)))
        #expect(kept == damaged)
        #expect(await log.verify() == .intact(count: 1))
    }

    @Test("a log cut short mid-record keeps its whole records, goes on from them, and keeps the cut file aside")
    func tornTailIsRepaired() async throws {
        let url = temporaryURL()
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: url)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasPrefix("\(stem).damaged-") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        let earlier = storedChain(3)
        var torn = try JSONEncoder().encode(earlier)
        torn.removeLast()
        torn.append(Data(#",{"sequence":3,"recordedAt":17000"#.utf8))
        try torn.write(to: url)

        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded.count == 4)
        #expect(decoded[3].sequence == 3)
        #expect(decoded[3].previousHash == earlier[2].hash)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(stem).damaged-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: directory.appendingPathComponent(try #require(kept.first))) == torn)
    }

    @Test("a file replaced by another of the same size is read again rather than written into")
    func sameSizeReplacementIsReadAgain() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        let written = try Data(contentsOf: url)

        let first = try decodedArray(at: url)[0]
        var replaced = Data("[".utf8) + (try JSONEncoder().encode(first)) + Data("]".utf8)
        replaced.append(Data(repeating: UInt8(ascii: " "), count: written.count - replaced.count))
        #expect(replaced.count == written.count)
        try replaced.write(to: url)

        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded.count == 2)
        #expect(decoded[1].previousHash == first.hash)
        #expect(await log.verify() == .intact(count: 2))
    }

    @Test("a record that cannot be written is held and written ahead of the next one")
    func unwrittenRecordIsHeldNotLost() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let log = ExecutionAuditLog(fileURL: url, retryInterval: .zero)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        await log.record(request: request(write: true), decision: .denied(reason: "x"))
        #expect(try decodedArray(at: url).count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded.map(\.sequence) == [0, 1, 2])
        #expect(decoded[1].kind == "writeQuery")
        #expect(await log.verify() == .intact(count: 3))
    }

    @Test("a record held on its first try after launch goes on from the log's last record once written")
    func heldRecordLinksToTheHeadAtWriteTime() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let earlier = storedChain(3)
        try JSONEncoder().encode(earlier).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        let log = ExecutionAuditLog(fileURL: url, retryInterval: .zero)
        await log.record(request: request(write: true), decision: .denied(reason: "x"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(decoded[3].previousHash == earlier[2].hash)
        #expect(decoded[3].kind == "writeQuery")
        #expect(await log.verify() == .intact(count: 5))
    }

    @Test("after a failed write the log waits before trying again, holding what was decided meanwhile")
    func failedWriteBacksOff() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let log = ExecutionAuditLog(fileURL: url, retryInterval: .seconds(3_600))
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        #expect(try decodedArray(at: url).count == 1)
    }

    @Test("a log replaced by another chain of the same size links to the replacement's last record")
    func sameSizeChainReplacementIsReadAgain() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ExecutionAuditLog(fileURL: url)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        let written = try decodedArray(at: url)

        var replacement: [ExecutionAuditRecord] = []
        for record in written {
            replacement.append(ExecutionAuditRecord(
                sequence: record.sequence,
                recordedAt: record.recordedAt,
                connectionId: UUID(),
                kind: record.kind,
                caller: record.caller,
                outcome: record.outcome,
                effectiveWrite: record.effectiveWrite,
                statementDigest: record.statementDigest,
                previousHash: replacement.last?.hash ?? ExecutionAuditRecord.genesisHash
            ))
        }
        let replaced = try JSONEncoder().encode(replacement)
        #expect(replaced.count == (try Data(contentsOf: url)).count)
        try replaced.write(to: url, options: .atomic)

        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        let decoded = try decodedArray(at: url)
        #expect(decoded[2].previousHash == replacement[1].hash)
        #expect(await log.verify() == .intact(count: 3))
    }

    @Test("an unreadable log that cannot be moved aside is left untouched until it can be")
    func unreadableLogThatCannotMoveIsKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("ExecutionAudit.json")
        let damaged = Data("not an array".utf8)
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let log = ExecutionAuditLog(fileURL: url, retryInterval: .zero)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))
        #expect(try Data(contentsOf: url) == damaged)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        await log.record(request: request(write: false), decision: .denied(reason: "x"))

        #expect(try decodedArray(at: url).map(\.sequence) == [0, 1])
        let setAside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ExecutionAudit.damaged-") }
        #expect(setAside.count == 1)
    }

    @Test("a damaged log reads as broken, not as an empty intact chain")
    func damagedLogVerifiesAsBroken() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        let log = ExecutionAuditLog(fileURL: url)

        #expect(await log.verify() == .broken(atSequence: 0))
    }

    @Test("the tail reader takes the last record whose opening brace follows a separator")
    func tailReaderFindsTheLastRecord() throws {
        let records = storedChain(2)
        let data = try JSONEncoder().encode(records)

        let head = try #require(ExecutionAuditLog.chainHead(inTail: data, startingAt: 0, fileSize: UInt64(data.count)))

        #expect(head.nextSequence == 2)
        #expect(head.lastHash == records[1].hash)
        #expect(head.closingBracketOffset == UInt64(data.count - 1))
        #expect(ExecutionAuditLog.chainHead(inTail: Data("[{}".utf8), startingAt: 0, fileSize: 3) == nil)
        #expect(ExecutionAuditLog.chainHead(inTail: Data("x[]".utf8), startingAt: 0, fileSize: 3) == nil)
    }
}
