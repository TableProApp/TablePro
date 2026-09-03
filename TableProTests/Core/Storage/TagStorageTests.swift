//
//  TagStorageTests.swift
//  TableProTests
//

import Combine
@testable import TablePro
import TableProSyncTransport
import XCTest

@MainActor
final class TagStorageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var syncSuiteName: String!
    private var syncDefaults: UserDefaults!
    private var metadata: SyncMetadataStorage!
    private var tracker: SyncChangeTracker!
    private var appEvents: AppEvents!
    private var storage: TagStorage!
    private var changeCount = 0
    private var changeSubscription: AnyCancellable?

    override func setUp() async throws {
        try await super.setUp()
        let unique = UUID().uuidString
        suiteName = "com.TablePro.tests.TagStorage.\(unique)"
        syncSuiteName = "com.TablePro.tests.TagStorage.sync.\(unique)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        syncDefaults = try XCTUnwrap(UserDefaults(suiteName: syncSuiteName))
        metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        tracker = SyncChangeTracker(metadataStorage: metadata)
        appEvents = AppEvents()
        changeCount = 0
        changeSubscription = appEvents.connectionUpdated.sink { [weak self] _ in
            self?.changeCount += 1
        }
        storage = TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: appEvents)
        changeCount = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        syncDefaults.removePersistentDomain(forName: syncSuiteName)
        changeSubscription = nil
        storage = nil
        appEvents = nil
        tracker = nil
        metadata = nil
        defaults = nil
        syncDefaults = nil
        suiteName = nil
        syncSuiteName = nil
        super.tearDown()
    }

    private var customTag: ConnectionTag {
        ConnectionTag(name: "staging", color: .orange)
    }

    /// A store already on disk when the app starts. `init` seeds the presets through `loadTags`,
    /// so an instance built first has a warm cache and never reads what a test writes after it.
    private func makeStorage(seeding payload: Data) -> TagStorage {
        defaults.set(payload, forKey: "com.TablePro.tags")
        return TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: appEvents)
    }

    // MARK: - Add

    func testAddTagReportsADuplicateName() throws {
        try storage.addTag(customTag)

        XCTAssertThrowsError(try storage.addTag(ConnectionTag(name: "STAGING", color: .blue))) { error in
            XCTAssertEqual(error as? TagStorageError, .duplicateName("STAGING"))
        }
        XCTAssertEqual(storage.loadTags().filter { $0.name.lowercased() == "staging" }.count, 1)
    }

    func testAddingATagAnnouncesTheChange() throws {
        try storage.addTag(customTag)

        XCTAssertEqual(changeCount, 1)
    }

    func testARefusedAddAnnouncesNothing() throws {
        try storage.addTag(customTag)
        changeCount = 0

        XCTAssertThrowsError(try storage.addTag(customTag))
        XCTAssertEqual(changeCount, 0)
    }

    // MARK: - Delete

    func testDeletingATagAnnouncesTheChange() throws {
        let tag = customTag
        try storage.addTag(tag)
        changeCount = 0

        storage.deleteTag(tag)

        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(metadata.tombstones(for: .tag).contains { $0.id == tag.id.uuidString })
    }

    func testAPresetIsNotDeleted() throws {
        let preset = try XCTUnwrap(ConnectionTag.presets.first)

        storage.deleteTag(preset)

        XCTAssertTrue(storage.loadTags().contains { $0.id == preset.id })
    }

    // MARK: - Remote Apply

    /// saveTags marks every tag dirty and the push uploads every dirty tag, so writing a record
    /// that changed nothing re-uploads the whole library to the device it came from.
    func testApplyingAnUnchangedRemoteTagWritesNothing() throws {
        let tag = customTag
        try storage.addTag(tag)
        tracker.clearAllDirty(.tag)

        XCTAssertFalse(storage.applyRemoteTag(tag))
        XCTAssertTrue(tracker.dirtyRecords(for: .tag).isEmpty)
    }

    func testApplyingARemoteTagAnnouncesNothing() {
        storage.applyRemoteTag(ConnectionTag(name: "from-another-mac"))

        XCTAssertEqual(changeCount, 0)
    }

    // MARK: - Unreadable Store

    func testAnUnreadableStoreIsLeftUntouched() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        let storage = makeStorage(seeding: junk)

        XCTAssertEqual(storage.loadTags().map(\.name), ConnectionTag.presets.map(\.name))
        XCTAssertThrowsError(try storage.addTag(customTag)) { error in
            XCTAssertEqual(error as? TagStorageError, .storeUnreadable)
        }
        XCTAssertEqual(
            defaults.data(forKey: "com.TablePro.tags"),
            junk,
            "Every mutation rewrites the whole array, so writing over a store we could not read replaces the user's tags with the presets"
        )
    }

    func testAnUnreadableEntryDoesNotTakeTheRestOfTheLibraryDown() throws {
        let keep = ConnectionTag(name: "keep", color: .green)
        let broken = ConnectionTag(name: "broken", color: .red)
        let encoded = try JSONEncoder().encode([keep, broken])
        var elements = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        elements[1]["isPreset"] = "not a bool"
        let storage = makeStorage(seeding: try JSONSerialization.data(withJSONObject: elements))

        XCTAssertEqual(storage.loadTags().map(\.name), ["keep"])
    }
}
