import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct GroupStorageUnreadableRecordTests {
    private static let key = "com.TablePro.groups"
    private static let unreadableId = UUID()
    private static let unreadableJSON =
        #"{"id":"\#(unreadableId.uuidString)","name":7,"shape":2,"extra":{"kept":[1,2.5,null,"text"]}}"#

    private let fixture: ProjectLibraryFixture

    init() throws {
        fixture = try ProjectLibraryFixture()
    }

    // A fresh store over a payload holding one readable group and one this build cannot decode.
    private func storageHoldingAnUnreadableGroup() throws -> (storage: GroupStorage, readable: ConnectionGroup) {
        let readable = ConnectionGroup(name: "Production")
        let encoded = String(decoding: try JSONEncoder().encode(readable), as: UTF8.self)
        fixture.defaults.set(Data("[\(encoded),\(Self.unreadableJSON)]".utf8), forKey: Self.key)
        let storage = GroupStorage(
            userDefaults: fixture.defaults,
            syncTracker: fixture.tracker,
            connectionStorage: fixture.connections,
            appEvents: fixture.appEvents
        )
        return (storage, readable)
    }

    private func storedRows() throws -> [NSDictionary] {
        let data = try #require(fixture.defaults.data(forKey: Self.key))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [NSDictionary])
    }

    private func unreadableRow() throws -> NSDictionary? {
        try storedRows().first { $0["id"] as? String == Self.unreadableId.uuidString }
    }

    private var originalRow: NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(Self.unreadableJSON.utf8)) as? NSDictionary
    }

    @Test("A group this build cannot read is kept as it was through an add, rename, move and delete of others")
    func unreadableRecordSurvivesEdits() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()
        #expect(storage.loadGroups().map(\.id) == [production.id])
        #expect(storage.unreadableGroupIds == [Self.unreadableId])
        #expect(!storage.storeIsUnreadable)

        let staging = ConnectionGroup(name: "Staging")
        try storage.addGroup(staging)
        #expect(try unreadableRow() == originalRow)

        try storage.mutateGroup(id: staging.id) { $0.name = "Staging EU" }
        #expect(try unreadableRow() == originalRow)

        try storage.moveGroups([staging.id], toParent: production.id, before: nil)
        #expect(try unreadableRow() == originalRow)

        try storage.restorePlacements([
            staging.id: ConnectionGroupPlacement(parentId: nil, projectId: nil, sortOrder: 5),
        ])
        #expect(try unreadableRow() == originalRow)

        #expect(storage.deleteGroup(production))
        #expect(try unreadableRow() == originalRow)

        #expect(storage.loadGroups().map(\.id) == [staging.id])
        #expect(try storedRows().count == 2)
        #expect(storage.unreadableGroupIds == [Self.unreadableId])
        #expect(!fixture.dirty(.group).contains(Self.unreadableId.uuidString))
    }

    @Test("The id of a group this build cannot read is taken: a save, an add and a pulled record cannot use it")
    func unreadableIdIsRefused() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()
        let impostor = ConnectionGroup(id: Self.unreadableId, name: "Impostor")

        #expect(!storage.saveGroups([production, impostor]))
        #expect(throws: GroupStorageError.storeUnreadable) {
            try storage.addGroup(impostor)
        }
        #expect(storage.applyRemoteGroup(impostor) == .failed)
        #expect(throws: GroupStorageError.groupNotFound) {
            try storage.mutateGroup(id: Self.unreadableId) { $0.name = "Renamed" }
        }

        #expect(storage.loadGroups().map(\.id) == [production.id])
        #expect(try unreadableRow() == originalRow)
        #expect(try storedRows().count == 2)
    }

    @Test("An import path makes its groups beside one this build cannot read")
    func importKeepsAnUnreadableGroup() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()

        let leaves = try storage.ensureGroupPaths([
            [PathComponent(name: "Production", scope: nil, color: nil)],
            [PathComponent(name: "Imported", scope: nil, color: nil)],
        ])

        #expect(leaves[0] == production.id)
        #expect(leaves[1] != Self.unreadableId)
        #expect(try unreadableRow() == originalRow)
        #expect(try storedRows().count == 3)
    }

    @Test("A connection in a group this build cannot read keeps naming it through other edits")
    func membersKeepTheirGroupId() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()
        let member = fixture.addConnection("member", groupId: Self.unreadableId)
        let other = fixture.addConnection("other", groupId: production.id)

        #expect(fixture.connections.moveConnections(
            [other.id], toGroup: nil, before: nil, groups: storage.loadGroups()
        ))
        #expect(storage.deleteGroup(production))

        #expect(fixture.stored(member)?.groupId == Self.unreadableId)
    }

    @Test("A deletion another device made removes a group this build cannot read by its id, and ungroups its members")
    func remoteDeletionRemovesAnUnreadableGroup() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()
        let member = fixture.addConnection("member", groupId: Self.unreadableId)

        #expect(storage.applyRemoteDeletions([Self.unreadableId]))

        #expect(storage.unreadableGroupIds.isEmpty)
        #expect(storage.loadGroups().map(\.id) == [production.id])
        #expect(try storedRows().count == 1)
        #expect(fixture.stored(member)?.groupId == nil)
        #expect(fixture.tombstones(.group).isEmpty)
    }

    @Test("A deletion of another group leaves one this build cannot read")
    func remoteDeletionOfAnotherGroupKeepsIt() throws {
        let (storage, production) = try storageHoldingAnUnreadableGroup()

        #expect(storage.applyRemoteDeletions([production.id]))

        #expect(storage.loadGroups().isEmpty)
        #expect(try unreadableRow() == originalRow)
    }
}
