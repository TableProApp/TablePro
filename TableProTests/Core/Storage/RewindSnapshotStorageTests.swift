//
//  RewindSnapshotStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class FakeRewindKeychain: KeychainStoring, @unchecked Sendable {
    private var values: [String: String] = [:]

    func writeString(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        values[key].map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

@Suite("Rewind snapshot storage")
struct RewindSnapshotStorageTests {
    private let connectionId = UUID()

    private func makeStorage() -> QueryHistoryStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-snapshots-\(UUID().uuidString).db")
        return QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    private func makeRecord(
        table: String = "users",
        schema: String? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        refusal: RewindRefusal? = nil
    ) -> RewindRecord {
        let target = DataWriteTarget(database: "shop", schema: schema, table: table)
        return RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: connectionId,
            databaseType: .sqlite,
            target: target,
            capturedAt: capturedAt,
            generatedColumns: [],
            operations: [
                RowWriteOperation(
                    kind: .update,
                    target: target,
                    columns: ["id", "name"],
                    primaryKeyColumns: ["id"],
                    preImage: ["7", "Ada"],
                    postImage: ["7", "Grace"],
                    writtenColumns: ["name"],
                    refusal: refusal
                ),
            ]
        )
    }

    @Test("A stored snapshot comes back with its rows intact")
    func roundTrip() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        let record = makeRecord()

        #expect(await storage.recordRewindSnapshot(record, cipher: cipher))
        let read = await storage.rewindSnapshot(id: record.id, cipher: cipher)
        #expect(read == record)
    }

    @Test("Snapshots come back newest first, and only for the table asked for")
    func listsByTargetNewestFirst() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        let older = makeRecord(capturedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeRecord(capturedAt: Date(timeIntervalSince1970: 2_000))
        let elsewhere = makeRecord(table: "orders")

        await storage.recordRewindSnapshot(older, cipher: cipher)
        await storage.recordRewindSnapshot(newer, cipher: cipher)
        await storage.recordRewindSnapshot(elsewhere, cipher: cipher)

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.map(\.id) == [newer.id, older.id])
    }

    @Test("A snapshot for another schema is not returned for the unqualified table")
    func schemaIsPartOfTheKey() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        await storage.recordRewindSnapshot(makeRecord(schema: "reporting"), cipher: cipher)

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.isEmpty)
    }

    @Test("Snapshots older than the retention window are pruned")
    func agePruning() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        let now = Date(timeIntervalSince1970: 2_000_000)
        await storage.recordRewindSnapshot(
            makeRecord(capturedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)), cipher: cipher
        )
        await storage.recordRewindSnapshot(makeRecord(capturedAt: now), cipher: cipher)

        await storage.pruneRewindSnapshots(now: now)

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.count == 1)
    }

    @Test("One table cannot hold more than the per-table depth")
    func perTablePruning() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        for offset in 0 ..< 6 {
            await storage.recordRewindSnapshot(
                makeRecord(capturedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + offset))), cipher: cipher
            )
        }

        await storage.pruneRewindSnapshots(now: Date(timeIntervalSince1970: 2_000), perTableLimit: 3)

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.count == 3)
    }

    @Test("A single save larger than the whole byte budget is still kept")
    func oversizedSingleSnapshotSurvives() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        await storage.recordRewindSnapshot(makeRecord(), cipher: cipher)

        await storage.pruneRewindSnapshots(now: Date(timeIntervalSince1970: 1_700_000_100), byteLimit: 1)

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.count == 1)
    }

    @Test("Clearing removes every snapshot")
    func clearing() async {
        let storage = makeStorage()
        let cipher = RewindCipher(keychain: FakeRewindKeychain())
        await storage.recordRewindSnapshot(makeRecord(), cipher: cipher)

        await storage.clearRewindSnapshots()

        let found = await storage.rewindSnapshots(
            connectionId: connectionId, database: "shop", schema: nil, table: "users", cipher: cipher
        )
        #expect(found.isEmpty)
    }
}
