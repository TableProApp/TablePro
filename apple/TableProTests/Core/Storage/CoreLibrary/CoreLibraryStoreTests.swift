//
//  CoreLibraryStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
struct CoreLibraryStoreTests {
    private let fixture: CoreLibraryFixture

    init() throws {
        fixture = try CoreLibraryFixture()
    }

    private func connection(_ name: String, group: UUID? = nil, favorite: Bool = false) -> DatabaseConnection {
        DatabaseConnection(name: name, host: "\(name).example.com", port: 5_432, type: .postgresql, groupId: group, isFavorite: favorite)
    }

    // MARK: - Moving in

    @Test("The first launch moves the earlier build's library into the core and leaves its files as they were")
    func firstLaunchMovesTheLibraryIn() throws {
        let group = ConnectionGroup(name: "Clients", color: .purple, iconName: "server.rack")
        let tag = ConnectionTag(name: "billing", color: .orange)
        let first = connection("alpha", group: group.id, favorite: true)
        let second = connection("beta", favorite: true)
        try fixture.writeAsPreviousStable(
            connections: [first, second],
            groups: [group],
            tags: ConnectionTag.presets + [tag],
            favoritesOrder: [second.id, first.id]
        )
        let before = try Data(contentsOf: fixture.legacyURL)

        let storage = fixture.launch()

        #expect(storage.loadConnections().map(\.name) == ["alpha", "beta"])
        #expect(fixture.groups(storage).loadGroups() == [group])
        #expect(fixture.tags(storage).loadTags() == ConnectionTag.presets + [tag])
        #expect(fixture.preferences(storage).favoritesOrder == [second.id, first.id])
        #expect(FileManager.default.fileExists(atPath: fixture.coreURL.path))
        #expect(try Data(contentsOf: fixture.legacyURL) == before)
    }

    @Test("Once moved in, the library reads from the core with the earlier build's files gone")
    func theCoreHoldsTheLibrary() throws {
        let group = ConnectionGroup(name: "Clients")
        try fixture.writeAsPreviousStable(connections: [connection("alpha", group: group.id)], groups: [group])
        _ = fixture.launch().loadConnections()

        let storage = try fixture.launchFromCoreOnly()

        #expect(storage.loadConnections().map(\.name) == ["alpha"])
        #expect(fixture.groups(storage).loadGroups() == [group])
    }

    // MARK: - The previous stable

    @Test("Every write lands in the core and in the stores the previous stable reads")
    func aWriteReachesBothStores() throws {
        let storage = fixture.launch()
        let groups = fixture.groups(storage)
        let tags = fixture.tags(storage)
        let group = ConnectionGroup(name: "Staging")
        try groups.addGroup(group)
        try tags.addTag(ConnectionTag(name: "eu-west", color: .blue))
        let added = connection("gamma", group: group.id, favorite: true)
        #expect(storage.addConnection(added))
        fixture.preferences(storage).setFavoritesOrder([added.id])

        #expect(try fixture.legacyConnections().map(\.name) == ["gamma"])
        #expect(try fixture.legacyConnections().first?.groupId == group.id)
        #expect(try fixture.legacyGroups().map(\.name) == ["Staging"])
        #expect(try fixture.legacyTags().contains { $0.name == "eu-west" })
        #expect(fixture.legacyFavoritesOrder == [added.id])

        let reopened = try fixture.launchFromCoreOnly()
        #expect(reopened.loadConnections().map(\.name) == ["gamma"])
        #expect(fixture.preferences(reopened).favoritesOrder == [added.id])
    }

    @Test("An edit the previous stable made while it ran is taken in at the next launch")
    func thePreviousStablesEditComesBack() throws {
        let storage = fixture.launch()
        let original = connection("alpha")
        #expect(storage.addConnection(original))

        var renamed = try #require(try fixture.legacyConnections().first)
        renamed.name = "alpha (edited on 0.88)"
        try fixture.writeAsPreviousStable(connections: [renamed, connection("added on 0.88")])

        let relaunched = fixture.launch()
        #expect(relaunched.loadConnections().map(\.name) == ["alpha (edited on 0.88)", "added on 0.88"])
        #expect(try fixture.launchFromCoreOnly().loadConnections().map(\.name) == ["alpha (edited on 0.88)", "added on 0.88"])
    }

    @Test("A deletion the previous stable made while it ran stays deleted")
    func thePreviousStablesDeletionComesBack() throws {
        let storage = fixture.launch()
        let kept = connection("kept")
        #expect(storage.addConnection(kept))
        #expect(storage.addConnection(connection("deleted on 0.88")))

        try fixture.writeAsPreviousStable(connections: [try #require(try fixture.legacyConnections().first)])

        #expect(fixture.launch().loadConnections().map(\.id) == [kept.id])
    }

    @Test("A write that stopped before its mirror keeps the core's copy, never the older files")
    func aWriteWithoutItsMirrorKeepsTheCore() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("first")))
        let legacyBefore = try Data(contentsOf: fixture.legacyURL)
        let groupsBefore = fixture.defaults.data(forKey: LegacyLibraryMirror.groupsKey)
        let tagsBefore = fixture.defaults.data(forKey: LegacyLibraryMirror.tagsKey)
        let orderBefore = fixture.defaults.stringArray(forKey: PreferenceKeys.connectionListFavoritesOrder.name)
        let recordBefore = fixture.defaults.data(forKey: LegacyLibraryMirror.recordKey)

        #expect(storage.addConnection(connection("second")))
        try legacyBefore.write(to: fixture.legacyURL, options: .atomic)
        fixture.defaults.set(groupsBefore, forKey: LegacyLibraryMirror.groupsKey)
        fixture.defaults.set(tagsBefore, forKey: LegacyLibraryMirror.tagsKey)
        fixture.defaults.set(orderBefore, forKey: PreferenceKeys.connectionListFavoritesOrder.name)
        fixture.defaults.set(recordBefore, forKey: LegacyLibraryMirror.recordKey)

        #expect(fixture.launch().loadConnections().map(\.name) == ["first", "second"])
        #expect(try fixture.legacyConnections().map(\.name) == ["first", "second"])
    }

    @Test("A connections.json that names one id twice moves in with the first, as every lookup by id read it")
    func aRepeatedIdKeepsTheFirst() throws {
        let first = connection("first")
        var repeated = first
        repeated.name = "repeated"
        try fixture.writeAsPreviousStable(connections: [first, repeated, connection("other")])

        let storage = fixture.launch()

        #expect(storage.loadConnections().map(\.name) == ["first", "other"])
        #expect(storage.addConnection(connection("added")))
    }

    @Test("A previous stable's change this build cannot read stops every write")
    func anUnreadableChangeIsNeverWrittenOver() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let junk = Data("not a list".utf8)
        fixture.defaults.set(junk, forKey: LegacyLibraryMirror.groupsKey)

        let relaunched = fixture.launch()

        #expect(relaunched.isLibraryUnreadable)
        #expect(!relaunched.addConnection(connection("beta")))
        #expect(fixture.defaults.data(forKey: LegacyLibraryMirror.groupsKey) == junk)
    }

    @Test("A core store that no longer parses is set aside and the library comes back from the mirror")
    func aDamagedCoreStoreComesBackFromTheMirror() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let damaged = Data("{\"version\": 1, \"connections\": [".utf8)
        try damaged.write(to: fixture.coreURL, options: .atomic)

        let relaunched = fixture.launch()

        #expect(relaunched.loadConnections().map(\.name) == ["alpha"])
        #expect(!relaunched.isLibraryUnreadable)
        #expect(try setAside("unreadable").map { try Data(contentsOf: $0) } == [damaged])
        #expect(try fixture.launchFromCoreOnly().loadConnections().map(\.name) == ["alpha"])
    }

    @Test("A core file a newer build wrote is never set aside or written over")
    func aNewerCoreFileIsKept() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let newer = Data(#"{"version": 99, "connections": []}"#.utf8)
        try newer.write(to: fixture.coreURL, options: .atomic)

        let relaunched = fixture.launch()

        #expect(relaunched.isLibraryUnreadable)
        #expect(!relaunched.addConnection(connection("beta")))
        #expect(try Data(contentsOf: fixture.coreURL) == newer)
        #expect(try setAside("unreadable").isEmpty)
    }

    @Test("A save that moves secrets out of the store removes the copies set aside, which still hold them")
    func movingSecretsOutRemovesSetAsideCopies() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try Data("not json".utf8).write(to: fixture.coreURL, options: .atomic)
        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(try setAside("unreadable").count == 1)

        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false, removingSecrets: true))

        #expect(try setAside("unreadable").isEmpty)
    }

    private func setAside(_ reason: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.coreURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("connections.json.\(reason)-") }
    }

    // MARK: - Records this build cannot read

    @Test("A connection the core cannot read is held, never written over, and a deletion from elsewhere removes it")
    func aHeldConnection() throws {
        let storage = fixture.launch()
        let readable = connection("alpha")
        #expect(storage.addConnection(readable))
        let heldId = UUID()
        try appendUnreadableCoreEntry(id: heldId)

        let relaunched = fixture.launch()
        #expect(relaunched.loadConnections().map(\.id) == [readable.id])
        #expect(relaunched.unreadableConnectionIds.contains(heldId))

        let taken = DatabaseConnection(id: heldId, name: "taken", type: .postgresql)
        #expect(!relaunched.saveConnections(relaunched.loadConnections() + [taken]))

        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false, removingUnreadable: [heldId]))
        #expect(!fixture.launch().unreadableConnectionIds.contains(heldId))
    }

    // A value a newer build wrote: a Safe Mode level no build knows yet.
    private func appendUnreadableCoreEntry(id: UUID) throws {
        let data = try Data(contentsOf: fixture.coreURL)
        var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var connections = try #require(document["connections"] as? [[String: Any]])
        var newer = try #require(connections.first)
        newer["id"] = id.uuidString.lowercased()
        newer["safe_mode"] = "paranoid"
        connections.append(newer)
        document["connections"] = connections
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.coreURL, options: .atomic)
    }

    // MARK: - Trust

    @Test("A core store changed outside TablePro is trusted again only rebuilt from what the user saved")
    func anEditedCoreStoreIsNotTrusted() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        #expect(storage.storeIsTrusted)
        let planted = UUID()
        try appendUnreadableCoreEntry(id: planted)

        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(!relaunched.storeIsTrusted)
        #expect(relaunched.unreadableConnectionIds.contains(planted))

        #expect(relaunched.addConnection(connection("beta")))
        #expect(relaunched.storeIsTrusted)
        #expect(!relaunched.unreadableConnectionIds.contains(planted))
        #expect(try setAside("untrusted").count == 1)
        let reopened = fixture.launch()
        #expect(reopened.loadConnections().map(\.name) == ["alpha", "beta"])
        #expect(reopened.storeIsTrusted)
    }

    @Test("A group, tag or favourites save never vouches for a core store changed outside TablePro")
    func onlyAConnectionSaveVouches() throws {
        let storage = fixture.launch()
        let favorite = connection("alpha", favorite: true)
        #expect(storage.addConnection(favorite))
        try appendUnreadableCoreEntry(id: UUID())

        let relaunched = fixture.launch()
        try fixture.groups(relaunched).addGroup(ConnectionGroup(name: "Staging"))
        try fixture.tags(relaunched).addTag(ConnectionTag(name: "eu-west"))
        fixture.preferences(relaunched).setFavoritesOrder([favorite.id])
        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false))

        #expect(!relaunched.storeIsTrusted)
        let reopened = fixture.launch()
        _ = reopened.loadConnections()
        #expect(!reopened.storeIsTrusted)
    }

    @Test("A mirror record that points at a planted core file brings nothing of it back")
    func aForgedMirrorRecordLaundersNothing() throws {
        let storage = fixture.launch()
        let kept = connection("kept")
        #expect(storage.addConnection(kept))
        let planted = UUID()
        try appendUnreadableCoreEntry(id: planted)
        let plantedDigest = LegacyLibraryMirror.digest(of: try Data(contentsOf: fixture.coreURL))
        let record = LegacyLibraryMirror.Record(legacy: "forged", core: plantedDigest, connectionsFileExisted: true)
        fixture.defaults.set(try JSONEncoder().encode(record), forKey: LegacyLibraryMirror.recordKey)

        let relaunched = fixture.launch()

        #expect(relaunched.loadConnections().map(\.id) == [kept.id])
        #expect(!relaunched.unreadableConnectionIds.contains(planted))
        #expect(relaunched.storeIsTrusted)
        #expect(try setAside("untrusted").count == 1)
    }

    @Test("A connections.json changed outside TablePro hands its doubt to the core")
    func anEditedLegacyFileStaysUntrusted() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        var bytes = try Data(contentsOf: fixture.legacyURL)
        bytes.append(contentsOf: Array(" ".utf8))
        try bytes.write(to: fixture.legacyURL, options: .atomic)

        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(!relaunched.storeIsTrusted)

        let again = fixture.launch()
        _ = again.loadConnections()
        #expect(!again.storeIsTrusted)
    }

    // MARK: - Favourites

    @Test("A favourite the order does not name yet follows the ordered ones by name")
    func favouritesFollowTheOrder() throws {
        let storage = fixture.launch()
        let zulu = connection("zulu", favorite: true)
        let alpha = connection("alpha", favorite: true)
        let pinned = connection("pinned", favorite: true)
        #expect(storage.saveConnections([zulu, alpha, pinned]))
        fixture.preferences(storage).setFavoritesOrder([pinned.id])

        #expect(fixture.preferences(storage).favoritesOrder == [pinned.id, alpha.id, zulu.id])
        #expect(storage.mutateConnections(ids: [alpha.id]) { $0.isFavorite = false })
        #expect(fixture.preferences(try fixture.launchFromCoreOnly()).favoritesOrder == [pinned.id, zulu.id])
    }
}
