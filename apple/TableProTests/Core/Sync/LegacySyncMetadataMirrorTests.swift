import CloudKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

struct LegacySyncMetadataMirrorTests {
    private static let zone = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: "_alice")
    private static let passAt = Date(timeIntervalSince1970: 1_767_300_000)

    private let suite: EphemeralDefaults
    private let metadata: SyncMetadataStorage
    private let directory: URL
    private let cache: SyncRecordCache
    private let mirror: LegacySyncMetadataMirror

    init() throws {
        suite = try EphemeralDefaults("LegacySyncMetadataMirrorTests")
        metadata = SyncMetadataStorage(userDefaults: suite.defaults)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySyncMetadataMirrorTests-\(UUID().uuidString)", isDirectory: true)
        cache = SyncRecordCache(directory: directory, defaults: nil)
        mirror = LegacySyncMetadataMirror(metadata: metadata, recordCache: cache, now: { Self.passAt })
    }

    private static func base(_ name: String, type: String = "ConnectionTag", fields: [CloudKitField]) -> CloudKitRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zone))
        return CloudKitRecord(
            recordType: type,
            name: name,
            systemFields: CloudKitRecordConversion.systemFields(of: record),
            createdMs: nil,
            fields: fields
        )
    }

    private static func record(_ type: SyncRecordType, _ id: String) -> LegacyRecordArg {
        LegacyRecordArg(recordType: type.rawValue, id: id)
    }

    private static func tombstone(_ type: SyncRecordType, _ id: String, at ms: Int64, owner: UUID? = nil) -> LegacyTombstoneArg {
        LegacyTombstoneArg(record: record(type, id), deletedAtMs: ms, owner: owner?.uuidString)
    }

    // What one committed pass hands the mirror, in the order the reader returns it.
    private static func pass(token: Data?, syncing: UUID, localOnly: UUID, owner: UUID) -> LegacyMetadataArg {
        LegacyMetadataArg(
            token: token,
            dirty: [record(.connection, "A"), record(.connection, "B"), record(.settings, "general")],
            tombstones: [
                tombstone(.group, "G1", at: 1_767_225_600_000),
                tombstone(.tableFavorite, "F1", at: 1_767_225_600_000, owner: owner)
            ],
            deferredDeletions: ["Favorite_X"],
            changesHeldForUnreadable: ["Connection_C"],
            removalsPendingForUnreadable: ["Group_R"],
            deletionsHeldForUnreadable: ["Connection_D"],
            ownersKeptOffSync: [owner.uuidString],
            standing: [
                LegacyStandingArg(connection: syncing.uuidString, standing: .syncs),
                LegacyStandingArg(connection: localOnly.uuidString, standing: .localOnly)
            ].sorted { $0.connection < $1.connection },
            readableRecordTypes: ["Connection", "ConnectionGroup"],
            account: "_alice",
            zoneState: SyncZoneState.confirmed.rawValue,
            cache: [base("Tag_A", fields: [CloudKitField(name: "name", value: .text(value: "Production"))])]
        )
    }

    @Test("A written pass reads back as it was written, so the engine can tell when an older build changed it")
    func writeThenReadRoundTrips() throws {
        let token = try #require(CloudKitChangeToken.archive(try CloudKitCoreTransportTests.changeToken()))
        let written = Self.pass(token: token, syncing: UUID(), localOnly: UUID(), owner: UUID())

        try mirror.write(metadata: written)

        #expect(try Self.comparable(mirror.read()) == Self.comparable(written))
    }

    // Records compared by what they hold: CloudKit re-encodes system fields when it rebuilds a record.
    private static func comparable(_ metadata: LegacyMetadataArg) -> LegacyMetadataArg {
        var copy = metadata
        copy.cache = metadata.cache.map { record in
            let rebuilt = record.systemFields.flatMap(CloudKitRecordConversion.rebuild)
            return CloudKitRecord(
                recordType: record.recordType,
                name: record.name,
                systemFields: rebuilt.map { Data($0.recordID.zoneID.ownerName.utf8) },
                createdMs: record.createdMs,
                fields: record.fields
            )
        }
        return copy
    }

    @Test("The previous stable reads the pass through its own metadata and record cache")
    func previousStableReadsThePass() throws {
        let token = try #require(CloudKitChangeToken.archive(try CloudKitCoreTransportTests.changeToken()))
        let syncing = UUID()
        let localOnly = UUID()
        let owner = UUID()

        try mirror.write(metadata: Self.pass(token: token, syncing: syncing, localOnly: localOnly, owner: owner))

        #expect(metadata.loadToken() != nil)
        #expect(metadata.dirtyIds(for: .connection) == ["A", "B"])
        #expect(metadata.dirtyIds(for: .settings) == ["general"])
        #expect(metadata.tombstones(for: .group).map(\.id) == ["G1"])
        #expect(metadata.tombstones(for: .group).first?.deletedAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(metadata.tombstones(for: .tableFavorite).first?.owner == owner)
        #expect(metadata.deferredDeletions == ["Favorite_X"])
        #expect(metadata.changesHeldForUnreadableCopies == ["Connection_C"])
        #expect(metadata.deletionsHeldForUnreadableCopies == ["Connection_D"])
        #expect(metadata.ownersKeptOffSync() == [owner])
        #expect(metadata.standing(ofConnection: syncing) == .syncs)
        #expect(metadata.standing(ofConnection: localOnly) == .keptOff)
        #expect(metadata.standing(ofConnection: UUID()) == .unknown)
        #expect(metadata.lastAccountId == "_alice")
        #expect(metadata.zoneState == .confirmed)
        #expect(metadata.lastSyncDate == Self.passAt)
        let cached = try #require(cache.record(named: "Tag_A"))
        #expect(cached["name"] as? String == "Production")
        #expect(cached.recordID.zoneID == Self.zone)
    }

    @Test("A pass replaces what an earlier one wrote: marks, sets and cached records it no longer names go")
    func aPassReplacesTheLastOne() throws {
        try mirror.write(metadata: Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID()))
        var next = LegacyMetadataArg(
            token: nil, dirty: [], tombstones: [], deferredDeletions: [], changesHeldForUnreadable: [],
            removalsPendingForUnreadable: [], deletionsHeldForUnreadable: [], ownersKeptOffSync: [], standing: [],
            readableRecordTypes: [], account: "_alice", zoneState: SyncZoneState.removed.rawValue, cache: []
        )
        next.cache = [Self.base("Tag_B", fields: [])]

        try mirror.write(metadata: next)

        #expect(SyncRecordType.allCases.allSatisfy { metadata.dirtyIds(for: $0).isEmpty })
        #expect(SyncRecordType.allCases.allSatisfy { metadata.tombstones(for: $0).isEmpty })
        #expect(metadata.deferredDeletions.isEmpty)
        #expect(metadata.changesHeldForUnreadableCopies.isEmpty)
        #expect(metadata.ownersKeptOffSync().isEmpty)
        #expect(metadata.connectionsKnownToSync().isEmpty)
        #expect(metadata.connectionsKeptOffSync().isEmpty)
        #expect(metadata.zoneState == .removed)
        #expect(cache.record(named: "Tag_A") == nil)
        #expect(cache.record(named: "Tag_B") != nil)
        #expect(try Self.comparable(mirror.read()) == Self.comparable(next))
    }

    @Test("Another account's position, tombstones and cached records go before its name is replaced")
    func anotherAccountsStateGoesFirst() throws {
        try mirror.write(metadata: Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID()))
        var bob = Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID())
        bob.account = "_bob"
        bob.tombstones = []
        bob.changesHeldForUnreadable = []
        bob.cache = [Self.base("Tag_B", fields: [])]

        try mirror.write(metadata: bob)

        #expect(metadata.lastAccountId == "_bob")
        #expect(SyncRecordType.allCases.allSatisfy { metadata.tombstones(for: $0).isEmpty })
        #expect(metadata.changesHeldForUnreadableCopies.isEmpty)
        #expect(cache.record(named: "Tag_A") == nil)
        #expect(cache.record(named: "Tag_B") != nil)
    }

    @Test("When the last account's records cannot be removed, its name stays, so the previous stable starts over")
    func aFailedSwitchKeepsTheLastAccountsName() throws {
        try mirror.write(metadata: Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID()))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        var bob = Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID())
        bob.account = "_bob"

        #expect(throws: HostSecretError.self) { try mirror.write(metadata: bob) }

        #expect(metadata.lastAccountId == "_alice")
        #expect(metadata.adoptAccount("_bob") == .switched)
    }

    @Test("A record type the previous stable does not know is left out of its marks")
    func unknownRecordTypesAreLeftOut() throws {
        var written = Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID())
        written.dirty.append(LegacyRecordArg(recordType: "ConnectionProject", id: "P1"))
        written.tombstones.append(LegacyTombstoneArg(
            record: LegacyRecordArg(recordType: "ConnectionProject", id: "P2"), deletedAtMs: 1, owner: nil
        ))

        try mirror.write(metadata: written)

        let read = try mirror.read()
        #expect(!read.dirty.contains { $0.recordType == "ConnectionProject" })
        #expect(!read.tombstones.contains { $0.record.recordType == "ConnectionProject" })
    }

    @Test("A base the previous stable could not merge against stays out of its record cache")
    func unusableBasesStayOutOfTheCache() throws {
        var written = Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID())
        written.cache = [
            CloudKitRecord(recordType: "ConnectionTag", name: "Tag_NoSystemFields", systemFields: nil, createdMs: nil, fields: []),
            Self.base("Tag_Renamed", fields: []).renamed("Tag_Other"),
            Self.base("Tag_Reserved", fields: [CloudKitField(name: "recordChangeTag", value: .text(value: "x"))])
        ]

        try mirror.write(metadata: written)

        #expect(try mirror.read().cache.isEmpty)
    }

    @Test("A zone state the engine does not know leaves the previous stable inferring it, as before the key existed")
    func anUnknownZoneStateIsForgotten() throws {
        metadata.zoneState = .removed
        var written = Self.pass(token: nil, syncing: UUID(), localOnly: UUID(), owner: UUID())
        written.zoneState = nil

        try mirror.write(metadata: written)

        #expect(metadata.zoneState == .confirmed)
    }

    @Test("A journal's marks reach the previous stable as SyncChangeTracker wrote them")
    func marksAreWhatTheTrackerWrote() throws {
        let owner = UUID()
        metadata.markDirty(["A"], type: .connection)
        metadata.addTombstones([Tombstone(id: "G1", deletedAt: Date(timeIntervalSince1970: 1))], type: .group)

        try mirror.mark(
            dirty: [Self.record(.connection, "B"), Self.record(.group, "G2")],
            tombstones: [
                Self.tombstone(.connection, "A", at: 1_767_225_600_000, owner: owner),
                Self.tombstone(.group, "G1", at: 1_767_225_600_000)
            ]
        )

        #expect(metadata.dirtyIds(for: .connection) == ["B"])
        #expect(metadata.dirtyIds(for: .group) == ["G2"])
        #expect(metadata.tombstones(for: .connection).map(\.id) == ["A"])
        #expect(metadata.tombstones(for: .connection).first?.owner == owner)
        #expect(metadata.tombstones(for: .group).map(\.id) == ["G1"])
        #expect(metadata.tombstones(for: .group).first?.deletedAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("Marks for a record type the previous stable does not know change nothing")
    func marksForUnknownTypesChangeNothing() throws {
        let before = try mirror.read()

        try mirror.mark(
            dirty: [LegacyRecordArg(recordType: "ConnectionProject", id: "P1")],
            tombstones: [LegacyTombstoneArg(
                record: LegacyRecordArg(recordType: "ConnectionProject", id: "P2"), deletedAtMs: 1, owner: nil
            )]
        )

        #expect(try mirror.read() == before)
    }
}

private extension CloudKitRecord {
    func renamed(_ name: String) -> CloudKitRecord {
        CloudKitRecord(recordType: recordType, name: name, systemFields: systemFields, createdMs: nil, fields: fields)
    }
}
