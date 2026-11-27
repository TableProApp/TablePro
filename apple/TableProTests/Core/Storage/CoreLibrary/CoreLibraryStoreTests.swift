//
//  CoreLibraryStoreTests.swift
//  TableProTests
//

import Foundation
import os
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
        #expect(try setAsideCopies().map { try Data(contentsOf: $0) } == [damaged])
        #expect(try fixture.launchFromCoreOnly().loadConnections().map(\.name) == ["alpha"])
    }

    @Test("A core file a newer build wrote is never set aside or written over")
    func aNewerCoreFileIsKept() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let newer = Data(#"{"version": 99, "connections": []}"#.utf8)
        try newer.write(to: fixture.coreURL, options: .atomic)
        #expect(fixture.stampCore(newer))

        let relaunched = fixture.launch()

        #expect(relaunched.isLibraryUnreadable)
        #expect(!relaunched.addConnection(connection("beta")))
        #expect(try Data(contentsOf: fixture.coreURL) == newer)
        #expect(try setAsideCopies().isEmpty)
    }

    @Test("A write whose mirror did not land, then the previous stable's edit, takes the edit in")
    func aMirrorThatDidNotLandTakesThePreviousStablesEdit() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("first")))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.directory.path)
        #expect(storage.addConnection(connection("only in the core")))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.directory.path)

        try fixture.writeAsPreviousStable(connections: [connection("edited on the previous stable")])

        #expect(fixture.launch().loadConnections().map(\.name) == ["edited on the previous stable"])
    }

    @Test("A save that moves secrets out of the store removes the copies set aside, which still hold them")
    func movingSecretsOutRemovesSetAsideCopies() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try Data("not json".utf8).write(to: fixture.coreURL, options: .atomic)
        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(try setAsideCopies().count == 1)

        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false, removingSecrets: true))

        #expect(try setAsideCopies().isEmpty)
    }

    private func keptCopies(named prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.coreURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("connections.json." + prefix) }
    }

    private func setAsideCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.coreURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("connections.json.corrupt-") || name.hasPrefix("connections.json.untrusted-")
            }
    }

    // MARK: - Records this build cannot read

    @Test("A connection the core cannot read is held, never written over, and a deletion from elsewhere removes it")
    func aHeldConnection() throws {
        let storage = fixture.launch()
        let readable = connection("alpha")
        #expect(storage.addConnection(readable))
        let heldId = UUID()
        try appendUnreadableCoreEntry(id: heldId, taggedByTablePro: true)

        let relaunched = fixture.launch()
        #expect(relaunched.loadConnections().map(\.id) == [readable.id])
        #expect(relaunched.unreadableConnectionIds.contains(heldId))

        let taken = DatabaseConnection(id: heldId, name: "taken", type: .postgresql)
        #expect(!relaunched.saveConnections(relaunched.loadConnections() + [taken]))

        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false, removingUnreadable: [heldId]))
        #expect(!fixture.launch().unreadableConnectionIds.contains(heldId))
    }

    @Test("A connection a pull leaves unreadable here keeps its copy in the previous stable's file")
    func aConnectionMadeUnreadableKeepsItsLegacyCopy() throws {
        let storage = fixture.launch()
        let alpha = connection("alpha")
        #expect(storage.saveConnections([alpha, connection("beta")]))
        try makeCoreEntryUnreadable(id: alpha.id)

        storage.readCoreWrites()

        #expect(storage.unreadableConnectionIds.contains(alpha.id))
        #expect(try fixture.legacyConnections().map(\.name).sorted() == ["alpha", "beta"])
    }

    @Test("A favourite connections.json holds unread keeps its place in the order after a relaunch")
    func anUnreadFavouriteKeepsItsPlace() throws {
        let kept = connection("kept", favorite: true)
        let unreadableId = UUID()
        let keptJSON = String(decoding: try JSONEncoder().encode(StoredConnection(from: kept)), as: UTF8.self)
        try Data(#"[\#(keptJSON),{"id":"\#(unreadableId.uuidString)","name":"From a newer build"}]"#.utf8)
            .write(to: fixture.legacyURL)
        fixture.defaults.set(
            [unreadableId.uuidString, kept.id.uuidString],
            forKey: PreferenceKeys.connectionListFavoritesOrder.name
        )
        _ = fixture.launch().loadConnections()

        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()

        #expect(fixture.preferences(relaunched).favoritesOrder == [unreadableId, kept.id])
        #expect(fixture.legacyFavoritesOrder == [unreadableId, kept.id])
    }

    private func makeCoreEntryUnreadable(id: UUID) throws {
        let data = try Data(contentsOf: fixture.coreURL)
        var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var connections = try #require(document["connections"] as? [[String: Any]])
        let index = try #require(connections.firstIndex { ($0["id"] as? String)?.lowercased() == id.uuidString.lowercased() })
        connections[index]["safe_mode"] = "paranoid"
        document["connections"] = connections
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.coreURL, options: .atomic)
    }

    // A value a newer build wrote: a Safe Mode level no build knows yet. A newer TablePro tags its write; anything else
    // leaves the tag as it was.
    private func appendUnreadableCoreEntry(id: UUID, taggedByTablePro: Bool = false) throws {
        let data = try Data(contentsOf: fixture.coreURL)
        var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var connections = try #require(document["connections"] as? [[String: Any]])
        var newer = try #require(connections.first)
        newer["id"] = id.uuidString.lowercased()
        newer["safe_mode"] = "paranoid"
        connections.append(newer)
        document["connections"] = connections
        let bytes = try JSONSerialization.data(withJSONObject: document)
        try bytes.write(to: fixture.coreURL, options: .atomic)
        if taggedByTablePro {
            #expect(fixture.stampCore(bytes))
        }
    }

    // A connection any reader would take, so the mirror carries it into connections.json.
    private func plantReadableCoreConnection(named name: String) throws {
        let data = try Data(contentsOf: fixture.coreURL)
        var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var connections = try #require(document["connections"] as? [[String: Any]])
        var planted = try #require(connections.first)
        planted["id"] = UUID().uuidString.lowercased()
        planted["name"] = name
        connections.append(planted)
        document["connections"] = connections
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.coreURL, options: .atomic)
    }

    private func editLegacyOutsideTablePro() throws {
        var bytes = try Data(contentsOf: fixture.legacyURL)
        bytes.append(contentsOf: Array(" ".utf8))
        try bytes.write(to: fixture.legacyURL, options: .atomic)
    }

    // MARK: - Trust

    @Test("A core store changed outside TablePro comes back from the previous stable's stores when those verify")
    func anEditedCoreStoreComesBackFromTheMirror() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let planted = UUID()
        try appendUnreadableCoreEntry(id: planted)

        let relaunched = fixture.launch()

        #expect(relaunched.loadConnections().map(\.name) == ["alpha"])
        #expect(relaunched.storeIsTrusted)
        #expect(!relaunched.unreadableConnectionIds.contains(planted))
        #expect(try setAsideCopies().count == 1)
    }

    @Test("With both stores changed outside TablePro, only a connection save rebuilds the store and vouches for it")
    func bothStoresEditedWaitForAConnectionSave() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let planted = UUID()
        try appendUnreadableCoreEntry(id: planted)
        try editLegacyOutsideTablePro()

        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(!relaunched.storeIsTrusted)
        #expect(relaunched.unreadableConnectionIds.contains(planted))

        #expect(relaunched.addConnection(connection("beta")))
        #expect(relaunched.storeIsTrusted)
        #expect(!relaunched.unreadableConnectionIds.contains(planted))
        #expect(try setAsideCopies().count == 1)
        let reopened = fixture.launch()
        #expect(reopened.loadConnections().map(\.name) == ["alpha", "beta"])
        #expect(reopened.storeIsTrusted)
    }

    @Test("A group, tag, favourites or sync write never vouches for either store")
    func onlyAConnectionSaveVouches() throws {
        let storage = fixture.launch()
        let favorite = connection("alpha", favorite: true)
        let second = connection("beta", favorite: true)
        #expect(storage.saveConnections([favorite, second]))
        try plantReadableCoreConnection(named: "planted")
        try editLegacyOutsideTablePro()

        let relaunched = fixture.launch()
        try fixture.groups(relaunched).addGroup(ConnectionGroup(name: "Staging"))
        try fixture.tags(relaunched).addTag(ConnectionTag(name: "eu-west"))
        fixture.preferences(relaunched).setFavoritesOrder([second.id, favorite.id])
        #expect(fixture.preferences(relaunched).favoritesOrder == [second.id, favorite.id])
        #expect(relaunched.saveConnections(relaunched.loadConnections(), byUser: false))

        #expect(!relaunched.storeIsTrusted)
        let legacy = try Data(contentsOf: fixture.legacyURL)
        #expect(ConnectionStoreIntegrity.shared.verify(legacy, fileURL: fixture.legacyURL) != .trusted)
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
        let record = LegacyLibraryMirror.Record(
            legacy: "forged", core: plantedDigest, connectionsFileExisted: true, legacyBehind: false
        )
        fixture.defaults.set(try JSONEncoder().encode(record), forKey: LegacyLibraryMirror.recordKey)

        let relaunched = fixture.launch()

        #expect(relaunched.loadConnections().map(\.id) == [kept.id])
        #expect(!relaunched.unreadableConnectionIds.contains(planted))
        #expect(relaunched.storeIsTrusted)
        #expect(try setAsideCopies().count == 1)
    }

    @Test("A write over a core file changed since the store read it is refused, and the next read goes back to the mirror")
    func aWriteOverAChangedFileIsRefused() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try plantReadableCoreConnection(named: "planted")

        #expect(!storage.saveConnections(storage.loadConnections(), byUser: false))

        #expect(storage.loadConnections().map(\.name) == ["alpha"])
        #expect(try setAsideCopies().count == 1)
    }

    @Test("A connection save over a core file changed since the store read it rebuilds the file from this Mac's library")
    func aSaveOverAChangedFileRebuilds() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try plantReadableCoreConnection(named: "planted")

        #expect(storage.addConnection(connection("beta")))

        #expect(storage.storeIsTrusted)
        #expect(try setAsideCopies().count == 1)
        let reopened = try fixture.launchFromCoreOnly()
        #expect(reopened.loadConnections().map(\.name) == ["alpha", "beta"])
        #expect(reopened.storeIsTrusted)
    }

    @Test("What another writer left in the core's file is read in after a sync pass, untrusted until a connection save")
    func aCoreWriteIsReadInAfterAPass() async throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try await writeAsTheCore { $0.connections[0].connection.name = "renamed by a pull" }

        storage.readCoreWrites()

        #expect(storage.loadConnections().map(\.name) == ["renamed by a pull"])
        #expect(!storage.storeIsTrusted)
        #expect(try fixture.legacyConnections().map(\.name) == ["renamed by a pull"])
        let legacy = try Data(contentsOf: fixture.legacyURL)
        #expect(ConnectionStoreIntegrity.shared.verify(legacy, fileURL: fixture.legacyURL) != .trusted)
        let reopened = fixture.launch()
        #expect(reopened.loadConnections().map(\.name) == ["renamed by a pull"])
        #expect(!reopened.storeIsTrusted)

        #expect(reopened.addConnection(connection("beta")))
        #expect(reopened.storeIsTrusted)
    }

    @Test("A connection save over a core file changed since a trusted read keeps the values only the core names")
    func aRebuildAfterATrustedReadKeepsStoredValues() async throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        try await writeAsTheCore { $0.connections[0].connection.color = "teal" }
        #expect(fixture.stampCore(try Data(contentsOf: fixture.coreURL)))
        let relaunched = fixture.launch()
        _ = relaunched.loadConnections()
        #expect(relaunched.storeIsTrusted)
        try plantReadableCoreConnection(named: "planted")

        #expect(relaunched.addConnection(connection("beta")))

        let colors = try await coreLibrary().libraryContents().connections.map { $0.connection.color }
        #expect(colors == ["teal", nil])
        #expect(relaunched.loadConnections().map(\.name) == ["alpha", "beta"])
    }

    @Test("A connection save over a file a newer build wrote since is refused and leaves the file as it is")
    func aSaveOverANewerFileIsRefused() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let newer = Data(#"{"version": 99, "connections": []}"#.utf8)
        try newer.write(to: fixture.coreURL, options: .atomic)

        #expect(!storage.addConnection(connection("beta")))

        #expect(try Data(contentsOf: fixture.coreURL) == newer)
        #expect(try setAsideCopies().isEmpty)
    }

    @Test("A library with no file yet is trusted, and its first write is tagged")
    func anEmptyLibraryStartsTrusted() throws {
        fixture.defaults.set(try JSONEncoder().encode([ConnectionTag]()), forKey: LegacyLibraryMirror.tagsKey)
        let storage = fixture.launch()
        #expect(storage.loadConnections().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.coreURL.path))
        #expect(storage.storeIsTrusted)

        try fixture.groups(storage).addGroup(ConnectionGroup(name: "Staging"))

        let reopened = fixture.launch()
        _ = reopened.loadConnections()
        #expect(reopened.storeIsTrusted)
    }

    // Another core over the same folder. Reporting, it seals its own writes as the app's core does for its engine.
    private func coreLibrary(reporting: Bool = false) throws -> ConnectionLibrary {
        let core = try Core(
            config: HostConfig(clientVersion: "test", storageDir: fixture.coreURL.deletingLastPathComponent().path),
            secrets: ConnectionKeychainSecrets(keychain: fixture.keychain) { _ in false }
        )
        if reporting, let key = ConnectionStoreIntegrity.shared.libraryReportKey() {
            try core.reportLibraryWrites(key: key)
        }
        return try core.library()
    }

    // A write the core makes on its own, as its engine does for a pull, which this Mac's store is not told of.
    private func writeAsTheCore(_ edit: (inout LibraryContents) -> Void) async throws {
        let library = try coreLibrary()
        var contents = try await library.libraryContents()
        edit(&contents)
        _ = try await library.replaceLibrary(
            library: LibraryWriteRecord(
                connections: contents.connections,
                groups: contents.groups,
                tags: contents.tags,
                favorites: contents.favorites,
                projects: contents.projects,
                sshProfiles: contents.sshProfiles,
                credentialProfiles: contents.credentialProfiles,
                removing: []
            ),
            over: contents.digest
        )
    }

    @Test("A credential profile another device deleted hands its credentials to a Local only connection here")
    func aPulledProfileDeletionHandsOverItsCredentials() async throws {
        let storage = fixture.launch()
        let profiles = fixture.credentialProfiles(storage)
        let reader = CredentialProfile(name: "Reader", username: "app_reader", passwordMode: .stored)
        #expect(profiles.addProfile(reader))
        #expect(profiles.savePassword("hunter2", for: reader.id))
        var linked = connection("linked")
        linked.localOnly = true
        linked.credentialMode = .profile(id: reader.id)
        linked.username = reader.username
        #expect(storage.addConnection(linked))

        try await writeAsTheCore { $0.credentialProfiles = [] }
        storage.readCoreWrites()

        let handedOver = try #require(storage.loadConnection(id: linked.id))
        #expect(handedOver.credentialMode == .inline)
        #expect(handedOver.username == "app_reader")
        #expect(storage.loadPassword(for: linked.id) == "hunter2")
        #expect(profiles.loadPassword(for: reader.id) == nil)
    }

    @Test("A profile a pull made unreadable here keeps the previous stable's copy")
    func aProfileHeldUnreadKeepsItsLegacyCopy() async throws {
        let storage = fixture.launch()
        let bastion = SSHProfile(name: "Bastion", host: "bastion.example.com", port: 22, username: "deploy")
        #expect(fixture.sshProfiles(storage).addProfile(bastion))

        let data = try Data(contentsOf: fixture.coreURL)
        var document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var held = try #require((document["ssh_profiles"] as? [[String: Any]])?.first)
        held["auth"] = ["kind": "a_method_from_a_newer_build"]
        document["ssh_profiles"] = [held]
        try JSONSerialization.data(withJSONObject: document).write(to: fixture.coreURL, options: .atomic)
        storage.readCoreWrites()
        #expect(storage.library.unreadableProfileIds == [bastion.id])
        try fixture.groups(storage).addGroup(ConnectionGroup(name: "Later"))

        let stored = try #require(fixture.defaults.data(forKey: "com.TablePro.sshProfiles"))
        #expect(try JSONDecoder().decode([SSHProfile].self, from: stored) == [bastion])
    }

    @Test("A write the core reports as its own, made over the file this Mac tagged, is tagged in turn")
    func aReportedCoreWriteIsTagged() async throws {
        let storage = fixture.launch()
        let alpha = connection("alpha")
        #expect(storage.addConnection(alpha))
        #expect(storage.storeIsTrusted)

        try await coreLibrary(reporting: true).renameConnection(id: alpha.id.uuidString, name: "renamed by a pull")
        storage.readCoreWrites()

        #expect(storage.loadConnections().map(\.name) == ["renamed by a pull"])
        #expect(storage.storeIsTrusted)
        let reopened = fixture.launch()
        #expect(reopened.loadConnections().map(\.name) == ["renamed by a pull"])
        #expect(reopened.storeIsTrusted)
    }

    @Test("A write the core reports, made over a file planted outside TablePro, is never tagged")
    func aReportedWriteOverAPlantedFileIsNotTagged() async throws {
        let storage = fixture.launch()
        let alpha = connection("alpha")
        #expect(storage.addConnection(alpha))
        try plantReadableCoreConnection(named: "planted")

        try await coreLibrary(reporting: true).renameConnection(id: alpha.id.uuidString, name: "renamed over the plant")
        storage.readCoreWrites()

        #expect(Set(storage.loadConnections().map(\.name)) == ["renamed over the plant", "planted"])
        #expect(!storage.storeIsTrusted)
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

        #expect(try keptCopies(named: "replaced-").count == 1)

        let again = fixture.launch()
        _ = again.loadConnections()
        #expect(!again.storeIsTrusted)
    }

    // MARK: - Projects

    @Test("Projects and their members live in the core, and the previous stable's stores keep a copy")
    func projectsGoThroughTheCore() throws {
        let storage = fixture.launch()
        let acme = try fixture.projects(storage).createProject(name: "Acme", color: .purple)
        let group = ConnectionGroup(name: "Production", projectId: acme.id)
        try fixture.groups(storage).addGroup(group)
        var loose = connection("loose")
        loose.projectId = acme.id
        #expect(storage.saveConnections([loose, connection("grouped", group: group.id)]))

        let relaunched = try fixture.launchFromCoreOnly()

        #expect(fixture.projects(relaunched).loadProjects().map(\.name) == ["Acme"])
        #expect(fixture.projects(relaunched).project(for: acme.id)?.color == .purple)
        #expect(relaunched.loadConnection(id: loose.id)?.projectId == acme.id)
        #expect(fixture.groups(relaunched).group(for: group.id)?.projectId == acme.id)
        #expect(try fixture.legacyProjects().map(\.id) == [acme.id])
        #expect(try fixture.legacyGroups().first?.projectId == acme.id)
    }

    @Test("A build's projects in the previous formats move into the core at the first launch")
    func projectsMoveIn() throws {
        let acme = ConnectionProject(name: "Acme", sortOrder: 0)
        var member = connection("member")
        member.projectId = acme.id
        let group = ConnectionGroup(name: "Staging", projectId: acme.id)
        try fixture.writeAsPreviousStable(connections: [member], groups: [group])
        fixture.defaults.set(try JSONEncoder().encode([acme]), forKey: "com.TablePro.projects")

        let storage = fixture.launch()

        #expect(fixture.projects(storage).loadProjects().map(\.id) == [acme.id])
        #expect(storage.loadConnection(id: member.id)?.projectId == acme.id)
        #expect(fixture.groups(storage).group(for: group.id)?.projectId == acme.id)
        #expect(try fixture.launchFromCoreOnly().loadConnection(id: member.id)?.projectId == acme.id)
    }

    @Test("A project the previous formats hold that this build cannot read stays in them as it was")
    func anUnreadProjectStaysInThePreviousFormats() throws {
        let acme = ConnectionProject(name: "Acme", sortOrder: 0)
        let unread = UUID()
        try fixture.writeAsPreviousStable(connections: [connection("member")], groups: [])
        var entries = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode([acme])) as? [Any]
        )
        entries.append(["id": unread.uuidString, "name": 7])
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: entries), forKey: "com.TablePro.projects")

        let storage = fixture.launch()
        try fixture.projects(storage).createProject(name: "Globex")

        let stored = try #require(fixture.defaults.data(forKey: "com.TablePro.projects"))
        let ids = try #require(try JSONSerialization.jsonObject(with: stored) as? [[String: Any]]).compactMap { $0["id"] as? String }
        #expect(ids.contains(unread.uuidString))
        #expect(ids.contains(acme.id.uuidString))
        #expect(ids.count == 3)
    }

    @Test("A project name with a tab, which the Mac let a person type, moves in with a space")
    func aProjectNameWithATabMovesIn() throws {
        let tabbed = ConnectionProject(name: "Acme\tWest", sortOrder: 0)
        try fixture.writeAsPreviousStable(connections: [connection("member")], groups: [])
        fixture.defaults.set(try JSONEncoder().encode([tabbed]), forKey: "com.TablePro.projects")

        let storage = fixture.launch()

        #expect(storage.loadConnections().map(\.name) == ["member"])
        #expect(try fixture.launchFromCoreOnly().library.current()?.projects.map(\.name) == ["Acme West"])
    }

    // MARK: - Profiles

    @Test("SSH and credential profiles live in the core, and the previous stable's stores keep a copy")
    func profilesGoThroughTheCore() throws {
        let storage = fixture.launch()
        let bastion = SSHProfile(name: "Bastion", host: "bastion.example.com", port: 2_222, username: "deploy")
        let reader = CredentialProfile(name: "Reader", username: "app_reader", passwordMode: .pgpass, secureFieldIds: ["token"])
        #expect(fixture.sshProfiles(storage).addProfile(bastion))
        #expect(fixture.credentialProfiles(storage).addProfile(reader))
        #expect(fixture.credentialProfiles(storage).storeIsTrusted)

        let relaunched = try fixture.launchFromCoreOnly()

        #expect(fixture.sshProfiles(relaunched).loadProfiles() == [bastion])
        #expect(fixture.credentialProfiles(relaunched).loadProfiles() == [reader])
        #expect(fixture.credentialProfiles(relaunched).storeIsTrusted)
        #expect(try fixture.legacySSHProfiles() == [bastion])
        #expect(try fixture.legacyCredentialProfiles() == [reader])
    }

    @Test("Profiles an earlier build kept only in the previous stable's stores move into the core once")
    func profilesMoveIntoAnEarlierCore() throws {
        let storage = fixture.launch()
        #expect(storage.addConnection(connection("alpha")))
        let bastion = SSHProfile(name: "Bastion", host: "bastion.example.com", username: "deploy")
        fixture.defaults.set(try JSONEncoder().encode([bastion]), forKey: "com.TablePro.sshProfiles")
        fixture.defaults.removeObject(forKey: LegacyLibraryMirror.profilesInCoreKey)
        // As an earlier build left it: its record names these stores, and its core file holds no profile.
        let mirror = LegacyLibraryMirror(
            fileURL: fixture.legacyURL,
            defaults: fixture.defaults,
            integrity: .shared,
            logger: Logger(subsystem: "com.TablePro", category: "tests")
        )
        mirror.record = LegacyLibraryMirror.Record(
            legacy: mirror.digest(),
            core: LegacyLibraryMirror.digest(of: try Data(contentsOf: fixture.coreURL)),
            connectionsFileExisted: true,
            legacyBehind: false
        )

        let relaunched = fixture.launch()

        #expect(fixture.sshProfiles(relaunched).loadProfiles() == [bastion])
        #expect(try fixture.launchFromCoreOnly().loadConnections().map(\.name) == ["alpha"])
        #expect(fixture.sshProfiles(fixture.launch()).loadProfiles() == [bastion])
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
