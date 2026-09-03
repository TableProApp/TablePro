//
//  GroupStorageTests.swift
//  TableProTests
//

import Combine
import TableProPluginKit
@testable import TablePro
import XCTest
import TableProSyncTransport

@MainActor
final class GroupStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var syncDefaults: UserDefaults!
    private var syncSuiteName: String!
    private var storage: GroupStorage!
    private var tracker: SyncChangeTracker!
    private var connectionStorage: ConnectionStorage!
    private var connectionFileURL: URL!
    private var appEvents: AppEvents!
    private var changeCount = 0
    private var changeSubscription: AnyCancellable?

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        suiteName = "com.TablePro.tests.GroupStorage.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)!
        syncSuiteName = "com.TablePro.tests.Sync.\(unique)"
        syncDefaults = UserDefaults(suiteName: syncSuiteName)!
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        tracker = SyncChangeTracker(metadataStorage: metadata)
        connectionFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("group-connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: connectionFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connectionStorage = ConnectionStorage(
            fileURL: connectionFileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
        appEvents = AppEvents()
        changeCount = 0
        changeSubscription = appEvents.connectionUpdated.sink { [weak self] _ in
            self?.changeCount += 1
        }
        storage = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: self.connectionStorage,
            appEvents: appEvents
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        try? FileManager.default.removeItem(at: connectionFileURL)
        defaults = nil
        suiteName = nil
        syncDefaults = nil
        syncSuiteName = nil
        changeSubscription = nil
        appEvents = nil
        storage = nil
        tracker = nil
        connectionStorage = nil
        connectionFileURL = nil
        super.tearDown()
    }

    // MARK: - Load

    func testLoadGroupsReturnsEmptyWhenNoData() {
        let groups = storage.loadGroups()
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Save and Load

    func testSaveAndLoadGroups() {
        let group1 = ConnectionGroup(name: "Development", color: .green)
        let group2 = ConnectionGroup(name: "Production", color: .red)

        storage.saveGroups([group1, group2])
        let loaded = storage.loadGroups()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Development")
        XCTAssertEqual(loaded[0].color, .green)
        XCTAssertEqual(loaded[1].name, "Production")
        XCTAssertEqual(loaded[1].color, .red)
    }

    // MARK: - Add

    func testAddGroup() throws {
        let group = ConnectionGroup(name: "Staging", color: .orange)
        try storage.addGroup(group)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Staging")
        XCTAssertEqual(loaded[0].id, group.id)
    }

    func testAddGroupReportsADuplicateSiblingName() throws {
        let group1 = ConnectionGroup(name: "Production", color: .red)
        let group2 = ConnectionGroup(name: "production", color: .blue)

        try storage.addGroup(group1)
        XCTAssertThrowsError(try storage.addGroup(group2)) { error in
            XCTAssertEqual(error as? GroupStorageError, .duplicateName("production"))
        }

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].color, .red)
    }

    func testAddGroupReportsANestingPastTheCap() throws {
        var parentId: UUID?
        for level in 0..<ConnectionGroup.maxNestingDepth {
            let group = ConnectionGroup(name: "L\(level)", parentId: parentId)
            try storage.addGroup(group)
            parentId = group.id
        }

        let tooDeep = ConnectionGroup(name: "TooDeep", parentId: parentId)
        XCTAssertThrowsError(try storage.addGroup(tooDeep)) { error in
            XCTAssertEqual(error as? GroupStorageError, .depthExceeded)
        }
        XCTAssertEqual(storage.loadGroups().count, ConnectionGroup.maxNestingDepth)
    }

    // MARK: - Update

    func testUpdateGroup() throws {
        let group = ConnectionGroup(name: "Dev", color: .green)
        try storage.addGroup(group)

        var updated = group
        updated.name = "Development"
        updated.color = .blue
        try storage.updateGroup(updated)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Development")
        XCTAssertEqual(loaded[0].color, .blue)
        XCTAssertEqual(loaded[0].id, group.id)
    }

    func testUpdateNonExistentGroupReportsItIsGone() throws {
        let group = ConnectionGroup(name: "Dev", color: .green)
        try storage.addGroup(group)

        let nonExistent = ConnectionGroup(name: "Other", color: .red)
        XCTAssertThrowsError(try storage.updateGroup(nonExistent)) { error in
            XCTAssertEqual(error as? GroupStorageError, .groupNotFound)
        }

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Dev")
    }

    func testUpdateGroupReportsAMoveInsideItself() throws {
        let parent = ConnectionGroup(name: "Parent")
        let child = ConnectionGroup(name: "Child", parentId: parent.id)
        try storage.addGroup(parent)
        try storage.addGroup(child)

        var moved = parent
        moved.parentId = child.id
        XCTAssertThrowsError(try storage.updateGroup(moved)) { error in
            XCTAssertEqual(error as? GroupStorageError, .wouldCreateCycle)
        }
        XCTAssertNil(storage.group(for: parent.id)?.parentId)
    }

    /// A move carries everything under it, so the rule is the subtree's depth and not the moved
    /// group's alone. Checking only the group would let a two-level subtree land one level down
    /// and push its own children past the cap, where the tree stops drawing them.
    func testUpdateGroupReportsAMoveThatWouldPushItsSubtreePastTheCap() throws {
        let top = ConnectionGroup(name: "Top")
        let subtreeRoot = ConnectionGroup(name: "SubtreeRoot")
        let subtreeLeaf = ConnectionGroup(name: "SubtreeLeaf", parentId: subtreeRoot.id)
        let topChild = ConnectionGroup(name: "TopChild", parentId: top.id)
        for group in [top, subtreeRoot, subtreeLeaf, topChild] {
            try storage.addGroup(group)
        }

        var moved = subtreeRoot
        moved.parentId = topChild.id
        XCTAssertThrowsError(try storage.updateGroup(moved)) { error in
            XCTAssertEqual(error as? GroupStorageError, .depthExceeded)
        }
        XCTAssertNil(storage.group(for: subtreeRoot.id)?.parentId)
    }

    // MARK: - Delete

    func testDeleteGroup() {
        let group1 = ConnectionGroup(name: "Dev", color: .green)
        let group2 = ConnectionGroup(name: "Prod", color: .red)
        storage.saveGroups([group1, group2])

        storage.deleteGroup(group1)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Prod")
    }

    func testDeleteGroupClearsMembershipAndMarksConnectionDirtyForSync() {
        let group = ConnectionGroup(name: "Dev", color: .green)
        storage.saveGroups([group])

        let connection = DatabaseConnection(name: "Grouped", groupId: group.id)
        connectionStorage.addConnection(connection)
        tracker.clearAllDirty(.connection)

        storage.deleteGroup(group)

        let reloaded = connectionStorage.loadConnections()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertNil(reloaded[0].groupId)
        XCTAssertTrue(tracker.dirtyRecords(for: .connection).contains(connection.id.uuidString))
    }

    // MARK: - Lookup

    func testGroupForId() throws {
        let group = ConnectionGroup(name: "Dev", color: .green)
        try storage.addGroup(group)

        let found = storage.group(for: group.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Dev")

        let notFound = storage.group(for: UUID())
        XCTAssertNil(notFound)
    }

    // MARK: - Rename Duplicate Guard

    func testUpdateGroupRejectsDuplicateName() throws {
        let group1 = ConnectionGroup(name: "Production", color: .red)
        let group2 = ConnectionGroup(name: "Staging", color: .orange)
        storage.saveGroups([group1, group2])

        // Renaming "Staging" to "Production" should be caught by caller, not storage.
        // Storage-level updateGroup does the raw save; the duplicate guard is in the UI layer.
        // Verify that two groups with same name CAN exist at storage level (the guard lives in WelcomeWindowView).
        var renamed = group2
        renamed.name = "Production"
        try storage.updateGroup(renamed)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 2)
        // Both now named "Production" — storage doesn't enforce uniqueness on update
        XCTAssertEqual(loaded[0].name, "Production")
        XCTAssertEqual(loaded[1].name, "Production")
    }

    // MARK: - Change Notification

    func testEveryMutationAnnouncesTheChange() throws {
        let group = ConnectionGroup(name: "Dev", color: .green)
        try storage.addGroup(group)
        XCTAssertEqual(changeCount, 1)

        var renamed = group
        renamed.name = "Development"
        try storage.updateGroup(renamed)
        XCTAssertEqual(changeCount, 2)

        storage.deleteGroup(renamed)
        XCTAssertEqual(changeCount, 3)
    }

    func testARefusedMutationAnnouncesNothing() throws {
        try storage.addGroup(ConnectionGroup(name: "Dev"))
        changeCount = 0

        XCTAssertThrowsError(try storage.addGroup(ConnectionGroup(name: "dev")))
        XCTAssertEqual(changeCount, 0)
    }

    /// A pull applies one record at a time and raises a single notification for the whole batch,
    /// so a per-record one here would multiply it by the number of groups that changed.
    func testApplyingARemoteGroupAnnouncesNothing() {
        storage.applyRemoteGroup(ConnectionGroup(name: "FromAnotherMac"))

        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(storage.loadGroups().count, 1)
    }

    // MARK: - Remote Apply

    /// A pull carries no dependency order. Judging one record against a graph the rest of the
    /// batch has not reached yet rooted the moved group for good, and the next push sent that back
    /// as a revert of a move the user made on the other Mac.
    func testAReversedHierarchySurvivesArrivingInEitherOrder() throws {
        let a = ConnectionGroup(name: "A")
        let b = ConnectionGroup(name: "B", parentId: a.id)
        try storage.addGroup(a)
        try storage.addGroup(b)

        var movedA = a
        movedA.parentId = b.id
        var rootedB = b
        rootedB.parentId = nil

        storage.applyRemoteGroup(movedA)
        storage.applyRemoteGroup(rootedB)
        XCTAssertFalse(storage.repairHierarchy())

        XCTAssertEqual(storage.group(for: a.id)?.parentId, b.id)
        XCTAssertNil(storage.group(for: b.id)?.parentId)
    }

    func testRepairHierarchyRootsAGroupLeftOnACycle() throws {
        let a = ConnectionGroup(name: "A")
        let b = ConnectionGroup(name: "B", parentId: a.id)
        try storage.addGroup(a)
        try storage.addGroup(b)

        var cyclicA = a
        cyclicA.parentId = b.id
        storage.applyRemoteGroup(cyclicA)

        XCTAssertTrue(storage.repairHierarchy())
        XCTAssertNil(storage.group(for: a.id)?.parentId)
        XCTAssertNil(storage.group(for: b.id)?.parentId)
        XCTAssertFalse(storage.repairHierarchy())
    }

    /// The list draws a cycle as two separate roots, so deleting one of them must not take the
    /// other with it, however the raw stored graph reads.
    func testDeletingAGroupLeftOnACycleKeepsTheOtherMember() throws {
        let a = ConnectionGroup(name: "A")
        let b = ConnectionGroup(name: "B", parentId: a.id)
        try storage.addGroup(a)
        try storage.addGroup(b)

        var cyclicA = a
        cyclicA.parentId = b.id
        storage.applyRemoteGroup(cyclicA)

        storage.deleteGroup(a)

        XCTAssertEqual(storage.loadGroups().map(\.id), [b.id])
    }

    /// saveGroups marks every group dirty and the push uploads every dirty group, so writing a
    /// record that changed nothing re-uploads the whole list to the device it came from.
    func testApplyingAnUnchangedRemoteGroupWritesNothing() throws {
        let group = ConnectionGroup(name: "Shared", color: .green)
        try storage.addGroup(group)
        tracker.clearAllDirty(.group)

        XCTAssertFalse(storage.applyRemoteGroup(group))
        XCTAssertTrue(tracker.dirtyRecords(for: .group).isEmpty)
    }

    // MARK: - Unreadable Store

    func testAnUnreadableStoreIsLeftUntouched() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        defaults.set(junk, forKey: "com.TablePro.groups")

        XCTAssertTrue(storage.loadGroups().isEmpty)
        XCTAssertThrowsError(try storage.addGroup(ConnectionGroup(name: "New"))) { error in
            XCTAssertEqual(error as? GroupStorageError, .storeUnreadable)
        }
        XCTAssertEqual(
            defaults.data(forKey: "com.TablePro.groups"),
            junk,
            "Every mutation rewrites the whole array, so writing over a store we could not read replaces it"
        )
    }

    func testAnUnreadableEntryDoesNotTakeTheRestOfTheListDown() throws {
        let keep = ConnectionGroup(name: "Keep", color: .green)
        let broken = ConnectionGroup(name: "Broken", color: .red)
        let encoded = try JSONEncoder().encode([keep, broken])
        var elements = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        elements[1]["sortOrder"] = "not a number"
        defaults.set(try JSONSerialization.data(withJSONObject: elements), forKey: "com.TablePro.groups")

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.map(\.name), ["Keep"])
    }

    // MARK: - Persistence

    func testGroupsPersistAcrossLoadCalls() throws {
        let group = ConnectionGroup(name: "Test", color: .purple)
        try storage.addGroup(group)

        let loaded1 = storage.loadGroups()
        let loaded2 = storage.loadGroups()
        XCTAssertEqual(loaded1.count, loaded2.count)
        XCTAssertEqual(loaded1[0].id, loaded2[0].id)
    }
}
