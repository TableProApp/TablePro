import Foundation
@testable import TablePro
import Testing
import TableProSyncTransport

@MainActor
struct CustomSlashCommandStorageSyncTests {
    private let commands: EphemeralDefaults
    private let metadata: EphemeralDefaults

    init() throws {
        commands = try EphemeralDefaults()
        metadata = try EphemeralDefaults()
    }

    private func makeStorage() -> (CustomSlashCommandStorage, SyncChangeTracker) {
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: metadata.defaults))
        let storage = CustomSlashCommandStorage(defaults: commands.defaults, syncTracker: tracker)
        return (storage, tracker)
    }

    @Test("Adding a command marks it dirty for sync")
    func addMarksDirty() throws {
        let (storage, tracker) = makeStorage()
        try storage.add(CustomSlashCommand(name: "explain", promptTemplate: "Explain {{query}}"))
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory))
    }

    @Test("Deleting a command marks it dirty for sync")
    func deleteMarksDirty() throws {
        let (storage, tracker) = makeStorage()
        let command = CustomSlashCommand(name: "explain", promptTemplate: "Explain {{query}}")
        try storage.add(command)
        tracker.clearAllDirty(.settings)
        storage.delete(id: command.id)
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory))
    }

    @Test("Applying remote commands replaces the list without marking dirty")
    func applyRemoteDoesNotMarkDirty() throws {
        let (storage, tracker) = makeStorage()
        storage.applyRemote([CustomSlashCommand(name: "remote", promptTemplate: "{{query}}")])
        #expect(storage.commands.map(\.name) == ["remote"])
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory) == false)
    }
}
