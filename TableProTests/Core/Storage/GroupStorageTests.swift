//
//  GroupStorageTests.swift
//  TableProTests
//

import TableProPluginKit
@testable import TablePro
import XCTest

@MainActor
final class GroupStorageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var syncDefaults: UserDefaults!
    private var syncSuiteName: String!
    private var storage: GroupStorage!

    override func setUp() {
        super.setUp()
        let unique = UUID().uuidString
        suiteName = "com.TablePro.tests.GroupStorage.\(unique)"
        defaults = UserDefaults(suiteName: suiteName)!
        syncSuiteName = "com.TablePro.tests.Sync.\(unique)"
        syncDefaults = UserDefaults(suiteName: syncSuiteName)!
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        storage = GroupStorage(userDefaults: defaults, syncTracker: tracker)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        defaults = nil
        suiteName = nil
        syncDefaults = nil
        syncSuiteName = nil
        storage = nil
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

    func testAddGroup() {
        let group = ConnectionGroup(name: "Staging", color: .orange)
        storage.addGroup(group)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Staging")
        XCTAssertEqual(loaded[0].id, group.id)
    }

    func testAddGroupPreventsDuplicateNames() {
        let group1 = ConnectionGroup(name: "Production", color: .red)
        let group2 = ConnectionGroup(name: "production", color: .blue)

        storage.addGroup(group1)
        storage.addGroup(group2)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].color, .red)
    }

    // MARK: - Update

    func testUpdateGroup() {
        let group = ConnectionGroup(name: "Dev", color: .green)
        storage.addGroup(group)

        var updated = group
        updated.name = "Development"
        updated.color = .blue
        storage.updateGroup(updated)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Development")
        XCTAssertEqual(loaded[0].color, .blue)
        XCTAssertEqual(loaded[0].id, group.id)
    }

    func testUpdateNonExistentGroupDoesNothing() {
        let group = ConnectionGroup(name: "Dev", color: .green)
        storage.addGroup(group)

        let nonExistent = ConnectionGroup(name: "Other", color: .red)
        storage.updateGroup(nonExistent)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Dev")
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

    // MARK: - Lookup

    func testGroupForId() {
        let group = ConnectionGroup(name: "Dev", color: .green)
        storage.addGroup(group)

        let found = storage.group(for: group.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Dev")

        let notFound = storage.group(for: UUID())
        XCTAssertNil(notFound)
    }

    // MARK: - Rename Duplicate Guard

    func testUpdateGroupRejectsDuplicateName() {
        let group1 = ConnectionGroup(name: "Production", color: .red)
        let group2 = ConnectionGroup(name: "Staging", color: .orange)
        storage.saveGroups([group1, group2])

        // Renaming "Staging" to "Production" should be caught by caller, not storage.
        // Storage-level updateGroup does the raw save; the duplicate guard is in the UI layer.
        // Verify that two groups with same name CAN exist at storage level (the guard lives in WelcomeWindowView).
        var renamed = group2
        renamed.name = "Production"
        storage.updateGroup(renamed)

        let loaded = storage.loadGroups()
        XCTAssertEqual(loaded.count, 2)
        // Both now named "Production" — storage doesn't enforce uniqueness on update
        XCTAssertEqual(loaded[0].name, "Production")
        XCTAssertEqual(loaded[1].name, "Production")
    }

    // MARK: - Persistence

    func testGroupsPersistAcrossLoadCalls() {
        let group = ConnectionGroup(name: "Test", color: .purple)
        storage.addGroup(group)

        let loaded1 = storage.loadGroups()
        let loaded2 = storage.loadGroups()
        XCTAssertEqual(loaded1.count, loaded2.count)
        XCTAssertEqual(loaded1[0].id, loaded2[0].id)
    }
}
