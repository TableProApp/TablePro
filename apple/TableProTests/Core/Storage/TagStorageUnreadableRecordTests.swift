import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct TagStorageUnreadableRecordTests {
    private static let key = "com.TablePro.tags"
    private static let unreadableId = UUID()

    private let suite: EphemeralDefaults
    private let syncSuite: EphemeralDefaults
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker

    init() throws {
        suite = try EphemeralDefaults("TagStorageUnreadableRecordTests")
        syncSuite = try EphemeralDefaults("TagStorageUnreadableRecordTests.sync")
        metadata = SyncMetadataStorage(userDefaults: syncSuite.defaults)
        tracker = SyncChangeTracker(metadataStorage: metadata)
    }

    private func unreadableJSON(id: UUID = unreadableId) -> String {
        #"{"id":"\#(id.uuidString)","name":7,"shape":2,"extra":{"kept":[1,2.5,null,"text"]}}"#
    }

    // The payload is on disk before the store is built, since `init` reads it to seed the presets.
    private func storageHoldingAnUnreadableTag(
        id: UUID = unreadableId
    ) throws -> (storage: TagStorage, readable: ConnectionTag) {
        let readable = ConnectionTag(name: "billing", color: .orange)
        let encoded = String(decoding: try JSONEncoder().encode(readable), as: UTF8.self)
        suite.defaults.set(Data("[\(encoded),\(unreadableJSON(id: id))]".utf8), forKey: Self.key)
        let storage = TagStorage(userDefaults: suite.defaults, syncTracker: tracker, appEvents: AppEvents())
        return (storage, readable)
    }

    private func storedRows() throws -> [NSDictionary] {
        let data = try #require(suite.defaults.data(forKey: Self.key))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [NSDictionary])
    }

    private func unreadableRow(id: UUID = unreadableId) throws -> NSDictionary? {
        try storedRows().first { $0["id"] as? String == id.uuidString }
    }

    private func originalRow(id: UUID = unreadableId) -> NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(unreadableJSON(id: id).utf8)) as? NSDictionary
    }

    @Test("A tag this build cannot read is kept as it was through an add, a pulled change and a delete of others")
    func unreadableRecordSurvivesEdits() throws {
        let (storage, billing) = try storageHoldingAnUnreadableTag()
        #expect(storage.loadTags().map(\.id) == [billing.id])
        #expect(storage.unreadableTagIds == [Self.unreadableId])
        #expect(!storage.storeIsUnreadable)

        let staging = ConnectionTag(name: "staging-eu", color: .blue)
        try storage.addTag(staging)
        #expect(try unreadableRow() == originalRow())

        var renamed = billing
        renamed.name = "invoicing"
        #expect(storage.applyRemoteTag(renamed) == .applied)
        #expect(try unreadableRow() == originalRow())

        storage.deleteTag(staging)
        #expect(try unreadableRow() == originalRow())

        #expect(storage.loadTags().map(\.name) == ["invoicing"])
        #expect(try storedRows().count == 2)
        #expect(storage.unreadableTagIds == [Self.unreadableId])
        #expect(!tracker.dirtyRecords(for: .tag).contains(Self.unreadableId.uuidString))
    }

    @Test("The id of a tag this build cannot read is taken: a save, an add and a pulled record cannot use it")
    func unreadableIdIsRefused() throws {
        let (storage, billing) = try storageHoldingAnUnreadableTag()
        let impostor = ConnectionTag(id: Self.unreadableId, name: "impostor")

        #expect(!storage.saveTags([billing, impostor]))
        #expect(throws: TagStorageError.storeUnreadable) {
            try storage.addTag(impostor)
        }
        #expect(storage.applyRemoteTag(impostor) == .failed)

        #expect(storage.loadTags().map(\.id) == [billing.id])
        #expect(try unreadableRow() == originalRow())
        #expect(try storedRows().count == 2)
    }

    @Test("An import never restores a preset over a record this build cannot read under the preset's id")
    func importTreatsAnUnreadableIdAsTaken() throws {
        let preset = try #require(ConnectionTag.presets.first)
        let (storage, _) = try storageHoldingAnUnreadableTag(id: preset.id)

        let ids = try storage.ensureTags([PlannedTag(name: preset.name, color: nil)])

        let imported = try #require(ids[preset.name.lowercased()])
        #expect(imported != preset.id)
        #expect(storage.tag(for: imported)?.name == preset.name)
        #expect(try unreadableRow(id: preset.id) == originalRow(id: preset.id))
        #expect(try storedRows().count == 3)
    }

    @Test("A deletion another device made removes a tag this build cannot read by its id, and no other")
    func remoteDeletionRemovesAnUnreadableTag() throws {
        let (storage, billing) = try storageHoldingAnUnreadableTag()

        #expect(storage.applyRemoteDeletions([billing.id]))
        #expect(try unreadableRow() == originalRow())

        #expect(storage.applyRemoteDeletions([Self.unreadableId]))
        #expect(storage.unreadableTagIds.isEmpty)
        #expect(try storedRows().isEmpty)
        #expect(metadata.tombstones(for: .tag).isEmpty)
    }
}
