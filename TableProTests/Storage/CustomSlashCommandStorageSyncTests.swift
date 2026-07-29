//
//  CustomSlashCommandStorageSyncTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("CustomSlashCommandStorage sync")
@MainActor
struct CustomSlashCommandStorageSyncTests {
    private func makeStorage() throws -> (CustomSlashCommandStorage, SyncChangeTracker) {
        let defaults = try #require(UserDefaults(suiteName: "slashcmd-\(UUID().uuidString)"))
        let metaDefaults = try #require(UserDefaults(suiteName: "slashcmd-meta-\(UUID().uuidString)"))
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: metaDefaults))
        let storage = CustomSlashCommandStorage(defaults: defaults, syncTracker: tracker)
        return (storage, tracker)
    }

    @Test("Adding a command marks it dirty for sync")
    func addMarksDirty() throws {
        let (storage, tracker) = try makeStorage()
        try storage.add(CustomSlashCommand(name: "explain", promptTemplate: "Explain {{query}}"))
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory))
    }

    @Test("Deleting a command marks it dirty for sync")
    func deleteMarksDirty() throws {
        let (storage, tracker) = try makeStorage()
        let command = CustomSlashCommand(name: "explain", promptTemplate: "Explain {{query}}")
        try storage.add(command)
        tracker.clearAllDirty(.settings)
        storage.delete(id: command.id)
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory))
    }

    @Test("Applying remote commands replaces the list without marking dirty")
    func applyRemoteDoesNotMarkDirty() throws {
        let (storage, tracker) = try makeStorage()
        storage.applyRemote([CustomSlashCommand(name: "remote", promptTemplate: "{{query}}")])
        #expect(storage.commands.map(\.name) == ["remote"])
        #expect(tracker.dirtyRecords(for: .settings).contains(CustomSlashCommandStorage.syncCategory) == false)
    }

    @Test("Custom slash commands round-trip through Codable")
    func codableRoundTrip() throws {
        let commands = [
            CustomSlashCommand(name: "explain", description: "Explain the query", promptTemplate: "Explain {{query}}"),
            CustomSlashCommand(name: "optimize", promptTemplate: "Optimize {{query}}"),
        ]
        let data = try JSONEncoder().encode(commands)
        let decoded = try JSONDecoder().decode([CustomSlashCommand].self, from: data)
        #expect(decoded == commands)
    }
}
