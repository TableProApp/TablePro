//
//  GroupStorageImportPathTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct GroupStorageImportPathTests {
    private let unique = UUID().uuidString
    private let defaults: UserDefaults
    private let metadata: SyncMetadataStorage
    private let events: AppEvents
    private let storage: GroupStorage

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.GroupImport.\(unique)"))
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.GroupImport.sync.\(unique)"))
        )
        let appEvents = AppEvents()
        events = appEvents
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let keychain = InMemoryKeychain()
        let connections = ConnectionStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("group-import-\(unique).json"),
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        storage = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: connections,
            appEvents: appEvents
        )
    }

    private func group(_ name: String, color: String? = nil) -> PathComponent {
        PathComponent(name: name, scope: nil, color: color)
    }

    @Test("The same leaf name under two parents stays two groups")
    func sameLeafUnderTwoParentsStaysDistinct() throws {
        let leaves = try storage.ensureGroupPaths([
            [group("Client A"), group("Production")],
            [group("Client B"), group("Production")]
        ])

        #expect(storage.loadGroups().count == 4)
        let underA = try #require(leaves[0])
        let underB = try #require(leaves[1])
        #expect(underA != underB)
        let clientA = try #require(storage.loadGroups().first { $0.name == "Client A" })
        let clientB = try #require(storage.loadGroups().first { $0.name == "Client B" })
        #expect(storage.group(for: underA)?.parentId == clientA.id)
        #expect(storage.group(for: underB)?.parentId == clientB.id)
    }

    @Test("An existing group is reused ignoring case, and only created groups take a color")
    func existingGroupIsReusedAndKeepsItsColor() throws {
        let client = ConnectionGroup(name: "Client A", color: .blue)
        try storage.addGroup(client)

        let leaves = try storage.ensureGroupPaths([[group("client a", color: "Red"), group("Production", color: "Green")]])

        #expect(storage.loadGroups().count == 2)
        #expect(storage.group(for: client.id)?.color == .blue)
        let leaf = try #require(leaves[0])
        let production = try #require(storage.group(for: leaf))
        #expect(production.parentId == client.id)
        #expect(production.color == .green)
    }

    @Test("A created group goes after the groups already beside it")
    func createdGroupGoesLast() throws {
        try storage.addGroup(ConnectionGroup(name: "Existing"))
        let existing = try #require(storage.loadGroups().first { $0.name == "Existing" })

        let leaves = try storage.ensureGroupPaths([[group("Imported")]])

        let leaf = try #require(leaves[0])
        let imported = try #require(storage.group(for: leaf))
        #expect(imported.sortOrder > existing.sortOrder)
    }

    @Test("One import saves once and announces once")
    func oneSaveAndOneAnnouncement() throws {
        var announcements = 0
        let subscription = events.connectionUpdated.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        _ = try storage.ensureGroupPaths([[group("A"), group("B")], [group("C")], [group("a"), group("b")]])

        #expect(announcements == 1)
        #expect(storage.loadGroups().count == 3)
        #expect(metadata.dirtyIds(for: .group) == Set(storage.loadGroups().map { $0.id.uuidString }))
    }

    @Test("Paths that already exist write nothing")
    func existingPathsWriteNothing() throws {
        let first = try storage.ensureGroupPaths([[group("A"), group("B")]])
        metadata.clearDirty(type: .group)
        var announcements = 0
        let subscription = events.connectionUpdated.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        let again = try storage.ensureGroupPaths([[group(" a "), group("B")]])

        #expect(again == first)
        #expect(announcements == 0)
        #expect(metadata.dirtyIds(for: .group).isEmpty)
    }

    @Test("An empty path has no group")
    func emptyPathHasNoGroup() throws {
        let leaves = try storage.ensureGroupPaths([[], [group("A")]])

        #expect(leaves.count == 2)
        #expect(leaves[0] == nil)
        #expect(leaves[1] != nil)
    }

    @Test("An unreadable group store throws and is left as it was")
    func unreadableStoreThrows() {
        let junk = Data([0x00, 0x01])
        defaults.set(junk, forKey: "com.TablePro.groups")

        #expect(throws: GroupStorageError.storeUnreadable) {
            try storage.ensureGroupPaths([[group("A")]])
        }
        #expect(defaults.data(forKey: "com.TablePro.groups") == junk)
    }
}
