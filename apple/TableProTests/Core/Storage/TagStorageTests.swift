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
    private var suite: EphemeralDefaults!
    private var defaults: UserDefaults!
    private var tracker: SyncJournalRecorder!
    private var appEvents: AppEvents!
    private var storage: TagStorage!
    private var changeCount = 0
    private var changeSubscription: AnyCancellable?

    override func setUp() async throws {
        try await super.setUp()
        suite = try EphemeralDefaults()
        defaults = suite.defaults
        tracker = SyncJournalRecorder()
        appEvents = AppEvents()
        changeCount = 0
        changeSubscription = appEvents.connectionUpdated.sink { [weak self] _ in
            self?.changeCount += 1
        }
        storage = TagStorage(userDefaults: defaults, syncJournal: tracker.journal, appEvents: appEvents)
        changeCount = 0
    }

    override func tearDown() {
        changeSubscription = nil
        storage = nil
        appEvents = nil
        tracker = nil
        defaults = nil
        suite = nil
        super.tearDown()
    }

    private var customTag: ConnectionTag {
        ConnectionTag(name: "staging", color: .orange)
    }

    /// A store already on disk when the app starts. `init` seeds the presets through `loadTags`,
    /// so an instance built first has a warm cache and never reads what a test writes after it.
    private func makeStorage(seeding payload: Data) -> TagStorage {
        defaults.set(payload, forKey: "com.TablePro.tags")
        return TagStorage(userDefaults: defaults, syncJournal: tracker.journal, appEvents: appEvents)
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
        XCTAssertTrue(tracker.tombstones(for: .tag).contains { $0.id == tag.id.uuidString })
    }

    func testAPresetIsNotDeleted() throws {
        let preset = try XCTUnwrap(ConnectionTag.presets.first)

        storage.deleteTag(preset)

        XCTAssertTrue(storage.loadTags().contains { $0.id == preset.id })
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
