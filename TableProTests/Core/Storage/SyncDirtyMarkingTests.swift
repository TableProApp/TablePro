import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct SyncDirtyMarkingTests {
    private let unique = UUID().uuidString
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker
    private let keychain = InMemoryKeychain()
    private let directory: URL
    private let connections: ConnectionStorage

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("dirty-marking-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.DirtyMarking.sync.\(unique)"))
        )
        tracker = SyncChangeTracker(metadataStorage: metadata)
        connections = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.DirtyMarking.conn.\(unique)")),
            syncTracker: tracker,
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
    }

    private func defaults(_ name: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "com.TablePro.tests.DirtyMarking.\(name).\(unique)"))
    }

    @Test("Saving the tag library marks the tag that changed and no other")
    func tagSaveMarksOnlyTheChangedTag() throws {
        let storage = TagStorage(userDefaults: try defaults("tags"), syncTracker: tracker, appEvents: AppEvents())
        let renamed = ConnectionTag(name: "staging")
        let untouched = ConnectionTag(name: "qa")
        try storage.addTag(renamed)
        try storage.addTag(untouched)
        metadata.clearDirty(type: .tag)

        let edited = storage.loadTags().map { tag -> ConnectionTag in
            guard tag.id == renamed.id else { return tag }
            var changed = tag
            changed.color = .purple
            return changed
        }
        #expect(storage.saveTags(edited))

        #expect(metadata.dirtyIds(for: .tag) == [renamed.id.uuidString])
    }

    @Test("Adding a tag marks the new tag alone")
    func addingATagMarksOnlyTheNewTag() throws {
        let storage = TagStorage(userDefaults: try defaults("tags-add"), syncTracker: tracker, appEvents: AppEvents())
        try storage.addTag(ConnectionTag(name: "staging"))
        metadata.clearDirty(type: .tag)
        let added = ConnectionTag(name: "qa")

        try storage.addTag(added)

        #expect(metadata.dirtyIds(for: .tag) == [added.id.uuidString])
    }

    @Test("Deleting a tag tombstones it and marks none of the others")
    func deletingATagMarksNothingElse() throws {
        let storage = TagStorage(userDefaults: try defaults("tags-delete"), syncTracker: tracker, appEvents: AppEvents())
        let doomed = ConnectionTag(name: "staging")
        try storage.addTag(doomed)
        try storage.addTag(ConnectionTag(name: "qa"))
        metadata.clearDirty(type: .tag)

        storage.deleteTag(doomed)

        #expect(metadata.dirtyIds(for: .tag).isEmpty)
        #expect(metadata.tombstones(for: .tag).map(\.id) == [doomed.id.uuidString])
    }

    @Test("Renaming a group marks that group alone")
    func groupRenameMarksOnlyThatGroup() throws {
        let storage = GroupStorage(
            userDefaults: try defaults("groups"),
            syncTracker: tracker,
            connectionStorage: connections,
            appEvents: AppEvents()
        )
        let renamed = ConnectionGroup(name: "Production")
        try storage.addGroup(renamed)
        try storage.addGroup(ConnectionGroup(name: "Staging"))
        metadata.clearDirty(type: .group)

        try storage.mutateGroup(id: renamed.id) { $0.name = "Prod" }

        #expect(metadata.dirtyIds(for: .group) == [renamed.id.uuidString])
    }

    @Test("Moving a group marks it for its new parent without marking its old siblings")
    func groupMoveMarksTheMovedGroup() throws {
        let storage = GroupStorage(
            userDefaults: try defaults("groups-move"),
            syncTracker: tracker,
            connectionStorage: connections,
            appEvents: AppEvents()
        )
        let parent = ConnectionGroup(name: "Clients")
        let moved = ConnectionGroup(name: "Acme")
        let sibling = ConnectionGroup(name: "Internal")
        try storage.addGroup(parent)
        try storage.addGroup(moved)
        try storage.addGroup(sibling)
        metadata.clearDirty(type: .group)

        try storage.moveGroups([moved.id], toParent: parent.id, before: nil)

        #expect(metadata.dirtyIds(for: .group) == [moved.id.uuidString])
    }

    @Test("Editing one SSH profile marks that profile alone")
    func sshProfileUpdateMarksOnlyThatProfile() throws {
        let storage = SSHProfileStorage(
            userDefaults: try defaults("ssh"),
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connections
        )
        var edited = SSHProfile(name: "Bastion", host: "bastion.example.com", username: "deploy")
        #expect(storage.addProfile(edited))
        #expect(storage.addProfile(SSHProfile(name: "Jump", host: "jump.example.com", username: "deploy")))
        metadata.clearDirty(type: .sshProfile)

        edited.host = "bastion2.example.com"
        #expect(storage.updateProfile(edited))

        #expect(metadata.dirtyIds(for: .sshProfile) == [edited.id.uuidString])
    }

    @Test("A remote removal of a table favorite this Mac no longer holds still drops its mark")
    func remoteRemovalOfAMissingFavoriteDropsTheMark() throws {
        let tables = FavoriteTablesStorage(userDefaults: try defaults("tables"), syncTracker: tracker)
        let tableId = String(repeating: "a", count: 64)
        tracker.markDirty(.tableFavorite, id: tableId)

        tables.removeFavoriteWithoutSync(id: tableId)

        #expect(metadata.dirtyIds(for: .tableFavorite).isEmpty)
    }

    @Test("Editing one credential profile marks that profile alone")
    func credentialProfileUpdateMarksOnlyThatProfile() throws {
        let storage = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connections,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        #expect(storage.addProfile(CredentialProfile(name: "Reader", username: "reader")))
        #expect(storage.addProfile(CredentialProfile(name: "Writer", username: "writer")))
        metadata.clearDirty(type: .credentialProfile)
        var edited = try #require(storage.loadProfiles().first { $0.name == "Reader" })

        edited.username = "reporting"
        #expect(storage.updateProfile(edited))

        #expect(metadata.dirtyIds(for: .credentialProfile) == [edited.id.uuidString])
    }
}
