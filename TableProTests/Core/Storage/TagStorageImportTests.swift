//
//  TagStorageImportTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct TagStorageImportTests {
    private let unique = UUID().uuidString
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker
    private let events: AppEvents

    init() throws {
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.TagImport.sync.\(unique)"))
        )
        tracker = SyncChangeTracker(metadataStorage: metadata)
        events = AppEvents()
    }

    private func makeStorage(_ name: String = "tags", seed: Data? = nil) throws -> (TagStorage, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.TagImport.\(name).\(unique)"))
        if let seed {
            defaults.set(seed, forKey: "com.TablePro.tags")
        }
        return (TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: events), defaults)
    }

    private func preset(_ name: String) throws -> ConnectionTag {
        try #require(ConnectionTag.presets.first { $0.name == name })
    }

    @Test("A preset wins over a custom tag of the same name")
    func presetWins() throws {
        let (storage, _) = try makeStorage()
        let production = try preset("production")
        let custom = ConnectionTag(name: "Production", color: .purple)
        #expect(storage.saveTags([custom] + storage.loadTags()))
        let countBefore = storage.loadTags().count

        let ids = try storage.ensureTags([PlannedTag(name: "PRODUCTION", color: "Blue")])

        #expect(ids == ["production": production.id])
        #expect(storage.loadTags().count == countBefore)
    }

    @Test("A missing tag is created once with its color, and an existing one matches ignoring case")
    func missingTagsAreCreatedOnce() throws {
        let (storage, _) = try makeStorage()
        let local = try preset("local")

        let ids = try storage.ensureTags([
            PlannedTag(name: "Billing", color: "Purple"),
            PlannedTag(name: "billing", color: "Red"),
            PlannedTag(name: "LOCAL", color: nil)
        ])

        let billingId = try #require(ids["billing"])
        let billing = try #require(storage.tag(for: billingId))
        #expect(billing.name == "Billing")
        #expect(billing.color == .purple)
        #expect(ids["local"] == local.id)
        #expect(storage.loadTags().filter { $0.name.lowercased() == "billing" }.count == 1)
    }

    @Test("A preset missing from the library comes back with its own id")
    func missingPresetIsRestored() throws {
        let (storage, _) = try makeStorage()
        let testing = try preset("testing")
        #expect(storage.saveTags(storage.loadTags().filter { $0.id != testing.id }))

        let ids = try storage.ensureTags([PlannedTag(name: "Testing", color: "Red")])

        #expect(ids["testing"] == testing.id)
        #expect(storage.tag(for: testing.id) == testing)
    }

    @Test("Only the tags an import creates are marked dirty, and it announces once")
    func onlyCreatedTagsAreDirty() throws {
        let (storage, _) = try makeStorage()
        #expect(storage.saveTags(storage.loadTags()))
        metadata.clearDirty(type: .tag)
        var announcements = 0
        let subscription = events.connectionUpdated.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        let ids = try storage.ensureTags([
            PlannedTag(name: "new-one", color: nil),
            PlannedTag(name: "new-two", color: "Green"),
            PlannedTag(name: "production", color: nil)
        ])

        let newOne = try #require(ids["new-one"])
        let newTwo = try #require(ids["new-two"])
        #expect(metadata.dirtyIds(for: .tag) == [newOne.uuidString, newTwo.uuidString])
        #expect(announcements == 1)
    }

    @Test("Matching every tag writes nothing")
    func matchingWritesNothing() throws {
        let (storage, defaults) = try makeStorage()
        #expect(storage.saveTags(storage.loadTags()))
        let before = defaults.data(forKey: "com.TablePro.tags")
        var announcements = 0
        let subscription = events.connectionUpdated.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        _ = try storage.ensureTags([PlannedTag(name: "Development", color: "Pink")])

        #expect(defaults.data(forKey: "com.TablePro.tags") == before)
        #expect(announcements == 0)
    }

    @Test("An unreadable tag store throws and is left as it was")
    func unreadableStoreThrows() throws {
        let junk = Data([0x00, 0x01])
        let (storage, defaults) = try makeStorage("unreadable", seed: junk)

        #expect(throws: TagStorageError.storeUnreadable) {
            try storage.ensureTags([PlannedTag(name: "Billing", color: nil)])
        }
        #expect(defaults.data(forKey: "com.TablePro.tags") == junk)
    }
}
