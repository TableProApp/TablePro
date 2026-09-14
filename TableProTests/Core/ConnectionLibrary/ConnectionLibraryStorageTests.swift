//
//  ConnectionLibraryStorageTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import TableProSyncTransport
import Testing

@MainActor
@Suite("Connection library storage")
struct ConnectionLibraryStorageTests {
    private let defaults: UserDefaults
    private let fileURL: URL
    private let appEvents: AppEvents
    private let storage: ConnectionStorage
    private let groupStorage: GroupStorage

    init() throws {
        let unique = UUID().uuidString
        let suiteDefaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.ConnectionLibraryStorage.\(unique)"))
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suiteDefaults))
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("library-connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let events = AppEvents()
        let connectionStorage = ConnectionStorage(
            fileURL: storeURL,
            userDefaults: suiteDefaults,
            syncTracker: tracker,
            appEvents: events
        )
        defaults = suiteDefaults
        fileURL = storeURL
        appEvents = events
        storage = connectionStorage
        groupStorage = GroupStorage(
            userDefaults: suiteDefaults,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            appEvents: events
        )
    }

    // MARK: - Connections

    @Test("A mutation changes only its field and announces the change once")
    func mutationKeepsOtherFields() {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        storage.addConnection(prod)
        #expect(storage.updateSafeModeLevel(.readOnly, for: prod.id))
        var announcements: [UUID?] = []
        let subscription = appEvents.connectionUpdated.sink { announcements.append($0) }

        #expect(storage.mutateConnections(ids: [prod.id]) { $0.isFavorite = true })

        let stored = storage.loadConnection(id: prod.id)
        #expect(stored?.isFavorite == true)
        #expect(stored?.preferredSafeModeLevel == .readOnly)
        #expect(announcements == [prod.id])
        subscription.cancel()
    }

    @Test("A mutation that changes nothing writes and announces nothing")
    func noOpMutation() {
        let prod = DatabaseConnection(name: "Prod", type: .postgresql)
        storage.addConnection(prod)
        var announcements = 0
        let subscription = appEvents.connectionUpdated.sink { _ in announcements += 1 }

        #expect(storage.mutateConnections(ids: [prod.id]) { $0.name = "Prod" })

        #expect(announcements == 0)
        subscription.cancel()
    }

    @Test("A new connection goes to the end of its group")
    func addAppendsToGroup() {
        let groupId = UUID()
        var first = DatabaseConnection(name: "Zeta", type: .mysql)
        first.groupId = groupId
        var second = DatabaseConnection(name: "Alpha", type: .mysql)
        second.groupId = groupId
        let elsewhere = DatabaseConnection(name: "Loose", type: .mysql)

        storage.addConnection(first)
        storage.addConnection(elsewhere)
        storage.addConnection(second)

        let stored = storage.loadConnections()
        #expect(stored.first { $0.id == first.id }?.sortOrder == 0)
        #expect(stored.first { $0.id == second.id }?.sortOrder == 1)
        #expect(stored.first { $0.id == elsewhere.id }?.sortOrder == 0)
    }

    @Test("Moving before a sibling renumbers that group in the new order")
    func moveBeforeRenumbers() {
        let a = DatabaseConnection(name: "A", type: .mysql)
        let b = DatabaseConnection(name: "B", type: .mysql)
        let c = DatabaseConnection(name: "C", type: .mysql)
        for connection in [a, b, c] {
            storage.addConnection(connection)
        }

        #expect(storage.moveConnections([c.id], toGroup: nil, before: a.id, validGroupIds: []))

        let order = LibrarySorting.sorted(storage.loadConnections(), mode: .manual).map(\.id)
        #expect(order == [c.id, a.id, b.id])
    }

    @Test("A connection pointing at a deleted group counts as ungrouped when moving")
    func orphanIsUngrouped() {
        var orphan = DatabaseConnection(name: "Orphan", type: .mysql, sortOrder: 7)
        orphan.groupId = UUID()
        storage.addConnection(orphan)
        let moving = DatabaseConnection(name: "Moving", type: .mysql)
        storage.addConnection(moving)
        let groupId = UUID()
        #expect(storage.mutateConnections(ids: [moving.id]) { $0.groupId = groupId })

        #expect(storage.moveConnections([moving.id], toGroup: nil, before: nil, validGroupIds: [groupId]))

        let stored = storage.loadConnection(id: moving.id)
        #expect(stored?.groupId == nil)
        #expect((stored?.sortOrder ?? 0) > 0)
    }

    @Test("A duplicate is placed right after its source")
    func duplicateFollowsSource() throws {
        let a = DatabaseConnection(name: "A", type: .mysql)
        let b = DatabaseConnection(name: "B", type: .mysql)
        storage.addConnection(a)
        storage.addConnection(b)

        let copy = try #require(storage.duplicateConnection(a))

        let order = LibrarySorting.sorted(storage.loadConnections(), mode: .manual).map(\.id)
        #expect(order == [a.id, copy.id, b.id])
    }

    @Test("Numbering an older store keeps it signed, so its password sources still run")
    func migrationKeepsStoreTrusted() {
        let first = DatabaseConnection(name: "First", type: .mysql, sortOrder: 0)
        let second = DatabaseConnection(name: "Second", type: .mysql, sortOrder: 0)
        #expect(storage.saveConnections([first, second]))
        guard storage.storeIsTrusted else {
            Issue.record("The connection store integrity key is unavailable in this test host")
            return
        }

        let migrating = ConnectionStorage(fileURL: fileURL, userDefaults: defaults)
        #expect(migrating.loadConnections().map(\.sortOrder) == [0, 1])

        let relaunched = ConnectionStorage(fileURL: fileURL, userDefaults: defaults)
        _ = relaunched.loadConnections()
        #expect(relaunched.storeIsTrusted)
    }

    @Test("Only a group whose connections are all unranked is numbered, in the order the list already showed")
    func numbersOnlyUnrankedGroups() {
        let groupId = UUID()
        var groupedFirst = DatabaseConnection(name: "G1", type: .mysql, sortOrder: 0)
        groupedFirst.groupId = groupId
        var groupedSecond = DatabaseConnection(name: "G2", type: .mysql, sortOrder: 0)
        groupedSecond.groupId = groupId
        let rankedFirst = DatabaseConnection(name: "L1", type: .mysql, sortOrder: 0)
        let rankedSecond = DatabaseConnection(name: "L2", type: .mysql, sortOrder: 3)
        var alone = DatabaseConnection(name: "Alone", type: .mysql, sortOrder: 0)
        alone.groupId = UUID()

        let numbered = ConnectionStorage.numberingUnrankedGroups(
            [groupedSecond, rankedFirst, groupedFirst, rankedSecond, alone]
        )

        #expect(numbered.map(\.sortOrder) == [1, 0, 0, 3, 0])
    }

    // MARK: - Groups

    @Test("A new group goes to the end of its parent")
    func addGroupAppends() throws {
        let first = ConnectionGroup(name: "Zeta")
        let second = ConnectionGroup(name: "Alpha")
        try groupStorage.addGroup(first)
        try groupStorage.addGroup(second)

        #expect(groupStorage.group(for: first.id)?.sortOrder == 0)
        #expect(groupStorage.group(for: second.id)?.sortOrder == 1)
    }

    @Test("Moving a group before a sibling renumbers the siblings")
    func moveGroupBefore() throws {
        let a = ConnectionGroup(name: "A")
        let b = ConnectionGroup(name: "B")
        let c = ConnectionGroup(name: "C")
        for group in [a, b, c] {
            try groupStorage.addGroup(group)
        }

        try groupStorage.moveGroups([c.id], toParent: nil, before: a.id)

        let graph = LibraryGroupGraph(groups: groupStorage.loadGroups())
        #expect(graph.sortedChildIds(of: nil, mode: .manual) == [c.id, a.id, b.id])
    }

    @Test("Moving a group under another nests it and refuses a move past the cap")
    func moveGroupNests() throws {
        let one = ConnectionGroup(name: "One")
        let two = ConnectionGroup(name: "Two", parentId: one.id)
        let three = ConnectionGroup(name: "Three", parentId: two.id)
        let moving = ConnectionGroup(name: "Moving")
        for group in [one, two, three, moving] {
            try groupStorage.addGroup(group)
        }

        try groupStorage.moveGroups([moving.id], toParent: one.id, before: nil)
        #expect(groupStorage.group(for: moving.id)?.parentId == one.id)

        #expect(throws: GroupStorageError.depthExceeded) {
            try groupStorage.moveGroups([moving.id], toParent: three.id, before: nil)
        }
    }

    @Test("Moving a group next to one with the same name is refused")
    func moveGroupDuplicateName() throws {
        let parent = ConnectionGroup(name: "Parent")
        let existing = ConnectionGroup(name: "Staging", parentId: parent.id)
        let moving = ConnectionGroup(name: "staging")
        for group in [parent, existing, moving] {
            try groupStorage.addGroup(group)
        }

        #expect(throws: GroupStorageError.duplicateName("staging")) {
            try groupStorage.moveGroups([moving.id], toParent: parent.id, before: nil)
        }
    }

    @Test("Renaming a group keeps the fields a stale copy would have overwritten")
    func mutateGroupKeepsColor() throws {
        let group = ConnectionGroup(name: "Dev", color: .green)
        try groupStorage.addGroup(group)
        try groupStorage.mutateGroup(id: group.id) { $0.color = .red }

        try groupStorage.mutateGroup(id: group.id) { $0.name = "Development" }

        #expect(groupStorage.group(for: group.id)?.name == "Development")
        #expect(groupStorage.group(for: group.id)?.color == .red)
    }

    @Test("A group nested past the cap by sync is still found for delete")
    func deleteReachesDeepGroups() throws {
        let one = ConnectionGroup(name: "1")
        let two = ConnectionGroup(name: "2", parentId: one.id)
        let three = ConnectionGroup(name: "3", parentId: two.id)
        let four = ConnectionGroup(name: "4", parentId: three.id)
        let five = ConnectionGroup(name: "5", parentId: four.id)
        #expect(groupStorage.saveGroups([one, two, three, four, five]))

        #expect(groupStorage.deleteGroup(one))

        #expect(groupStorage.loadGroups().isEmpty)
    }
}
