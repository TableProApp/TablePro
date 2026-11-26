import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct SyncDirtyMarkingTests {
    private let unique = UUID().uuidString
    private let pool = EphemeralDefaultsPool()
    private let tracker: SyncJournalRecorder
    private let keychain = InMemoryKeychain()
    private let directory: URL
    private let connections: ConnectionStorage

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("dirty-marking-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tracker = SyncJournalRecorder()
        connections = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: try pool.make().defaults,
            syncJournal: tracker.journal,
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
    }

    private func defaults(_ name: String) throws -> UserDefaults {
        try pool.make(name).defaults
    }

    @Test("Saving the tag library marks the tag that changed and no other")
    func tagSaveMarksOnlyTheChangedTag() throws {
        let storage = TagStorage(userDefaults: try defaults("tags"), syncJournal: tracker.journal, appEvents: AppEvents())
        let renamed = ConnectionTag(name: "staging")
        let untouched = ConnectionTag(name: "qa")
        try storage.addTag(renamed)
        try storage.addTag(untouched)
        tracker.clearDirty(type: .tag)

        let edited = storage.loadTags().map { tag -> ConnectionTag in
            guard tag.id == renamed.id else { return tag }
            var changed = tag
            changed.color = .purple
            return changed
        }
        #expect(storage.saveTags(edited))

        #expect(tracker.dirtyIds(for: .tag) == [renamed.id.uuidString])
    }

    @Test("Adding a tag marks the new tag alone")
    func addingATagMarksOnlyTheNewTag() throws {
        let storage = TagStorage(userDefaults: try defaults("tags-add"), syncJournal: tracker.journal, appEvents: AppEvents())
        try storage.addTag(ConnectionTag(name: "staging"))
        tracker.clearDirty(type: .tag)
        let added = ConnectionTag(name: "qa")

        try storage.addTag(added)

        #expect(tracker.dirtyIds(for: .tag) == [added.id.uuidString])
    }

    @Test("Deleting a tag tombstones it and marks none of the others")
    func deletingATagMarksNothingElse() throws {
        let storage = TagStorage(userDefaults: try defaults("tags-delete"), syncJournal: tracker.journal, appEvents: AppEvents())
        let doomed = ConnectionTag(name: "staging")
        try storage.addTag(doomed)
        try storage.addTag(ConnectionTag(name: "qa"))
        tracker.clearDirty(type: .tag)

        storage.deleteTag(doomed)

        #expect(tracker.dirtyIds(for: .tag).isEmpty)
        #expect(tracker.tombstones(for: .tag).map(\.id) == [doomed.id.uuidString])
    }

    @Test("Renaming a group marks that group alone")
    func groupRenameMarksOnlyThatGroup() throws {
        let storage = GroupStorage(
            userDefaults: try defaults("groups"),
            syncJournal: tracker.journal,
            connectionStorage: connections,
            appEvents: AppEvents()
        )
        let renamed = ConnectionGroup(name: "Production")
        try storage.addGroup(renamed)
        try storage.addGroup(ConnectionGroup(name: "Staging"))
        tracker.clearDirty(type: .group)

        try storage.mutateGroup(id: renamed.id) { $0.name = "Prod" }

        #expect(tracker.dirtyIds(for: .group) == [renamed.id.uuidString])
    }

    @Test("Moving a group marks it for its new parent without marking its old siblings")
    func groupMoveMarksTheMovedGroup() throws {
        let storage = GroupStorage(
            userDefaults: try defaults("groups-move"),
            syncJournal: tracker.journal,
            connectionStorage: connections,
            appEvents: AppEvents()
        )
        let parent = ConnectionGroup(name: "Clients")
        let moved = ConnectionGroup(name: "Acme")
        let sibling = ConnectionGroup(name: "Internal")
        try storage.addGroup(parent)
        try storage.addGroup(moved)
        try storage.addGroup(sibling)
        tracker.clearDirty(type: .group)

        try storage.moveGroups([moved.id], toParent: parent.id, before: nil)

        #expect(tracker.dirtyIds(for: .group) == [moved.id.uuidString])
    }

    @Test("Editing one SSH profile marks that profile alone")
    func sshProfileUpdateMarksOnlyThatProfile() throws {
        let storage = SSHProfileStorage(
            userDefaults: try defaults("ssh"),
            keychain: keychain,
            syncJournal: tracker.journal,
            connectionStorage: connections
        )
        var edited = SSHProfile(name: "Bastion", host: "bastion.example.com", username: "deploy")
        #expect(storage.addProfile(edited))
        #expect(storage.addProfile(SSHProfile(name: "Jump", host: "jump.example.com", username: "deploy")))
        tracker.clearDirty(type: .sshProfile)

        edited.host = "bastion2.example.com"
        #expect(storage.updateProfile(edited))

        #expect(tracker.dirtyIds(for: .sshProfile) == [edited.id.uuidString])
    }

    @Test("Editing one credential profile marks that profile alone")
    func credentialProfileUpdateMarksOnlyThatProfile() throws {
        let storage = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            syncJournal: tracker.journal,
            connectionStorage: connections,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        #expect(storage.addProfile(CredentialProfile(name: "Reader", username: "reader")))
        #expect(storage.addProfile(CredentialProfile(name: "Writer", username: "writer")))
        tracker.clearDirty(type: .credentialProfile)
        var edited = try #require(storage.loadProfiles().first { $0.name == "Reader" })

        edited.username = "reporting"
        #expect(storage.updateProfile(edited))

        #expect(tracker.dirtyIds(for: .credentialProfile) == [edited.id.uuidString])
    }
}
