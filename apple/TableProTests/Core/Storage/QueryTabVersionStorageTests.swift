//
//  QueryTabVersionStorageTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import Testing

struct QueryTabVersionStorageTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private let url: URL
    private let now = OSAllocatedUnfairLock(initialState: QueryTabVersionStorageTests.start)
    private let historyMaxDays = OSAllocatedUnfairLock(initialState: 90)
    private let announced = OSAllocatedUnfairLock(initialState: [UUID?]())
    private let storage: QueryTabVersionStorage
    private let tabId = UUID()
    private let connectionId = UUID()

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("query_tab_versions_\(UUID().uuidString).db")
        self.url = url
        storage = Self.makeStorage(
            url: url,
            now: now,
            historyMaxDays: historyMaxDays,
            announced: announced,
            removeDatabaseOnDeinit: true
        )
    }

    private static func makeStorage(
        url: URL,
        now: OSAllocatedUnfairLock<Date>,
        historyMaxDays: OSAllocatedUnfairLock<Int>,
        announced: OSAllocatedUnfairLock<[UUID?]>,
        removeDatabaseOnDeinit: Bool
    ) -> QueryTabVersionStorage {
        QueryTabVersionStorage(
            databaseURL: url,
            now: { now.withLock { $0 } },
            historyMaxDays: { historyMaxDays.withLock { $0 } },
            announce: { tabId in announced.withLock { $0.append(tabId) } },
            removeDatabaseOnDeinit: removeDatabaseOnDeinit
        )
    }

    private func reopenedStorage() -> QueryTabVersionStorage {
        Self.makeStorage(
            url: url,
            now: now,
            historyMaxDays: historyMaxDays,
            announced: announced,
            removeDatabaseOnDeinit: false
        )
    }

    private func advance(by seconds: TimeInterval) {
        now.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    @discardableResult
    private func record(_ text: String, _ reason: QueryTabVersionReason = .run, tab: UUID? = nil) async -> Bool {
        await storage.record(tabId: tab ?? tabId, connectionId: connectionId, text: text, reason: reason)
    }

    private func texts(tab: UUID? = nil) -> [String] {
        let id = tab ?? tabId
        return storage.summaries(tabId: id, limit: 200).compactMap { storage.version(id: $0.id, tabId: id)?.query }
    }

    @Test("Blank text is not recorded")
    func blankTextIsSkipped() async {
        #expect(await record("  \n\t ") == false)
        #expect(storage.summaries(tabId: tabId).isEmpty)
    }

    @Test("Text larger than a tab can persist is not recorded")
    func oversizeTextIsSkipped() async {
        let oversize = String(repeating: "x", count: TabQueryContent.maxPersistableQuerySize + 1)
        #expect(await record(oversize) == false)
        #expect(storage.summaries(tabId: tabId).isEmpty)
    }

    @Test("Text identical to the tab's newest version is not recorded again")
    func duplicateOfNewestIsSkipped() async {
        #expect(await record("SELECT 1"))
        #expect(await record("SELECT 1", .beforeReplace) == false)
        #expect(await record("SELECT 2"))
        #expect(await record("SELECT 1"))
        #expect(texts() == ["SELECT 1", "SELECT 2", "SELECT 1"])
    }

    @Test("A tab keeps its 50 newest versions")
    func capKeepsTheNewest() async {
        for index in 1...55 {
            await record("SELECT \(index)")
        }
        let kept = texts()
        #expect(kept.count == QueryTabVersionStorage.retainedVersionCount)
        #expect(kept.first == "SELECT 55")
        #expect(kept.last == "SELECT 6")
    }

    @Test("The cap counts each tab on its own")
    func capIsPerTab() async {
        let other = UUID()
        for index in 1...55 {
            await record("SELECT \(index)")
        }
        await record("SELECT other", tab: other)
        #expect(texts(tab: other) == ["SELECT other"])
    }

    @Test("Versions older than 30 days are gone, read or written")
    func versionsExpireAfterThirtyDays() async {
        await record("SELECT 1")
        advance(by: 29 * 86_400)
        await record("SELECT 2")
        #expect(texts() == ["SELECT 2", "SELECT 1"])

        advance(by: 2 * 86_400)
        #expect(texts() == ["SELECT 2"])

        await record("SELECT 3")
        let reopened = reopenedStorage()
        #expect(reopened.summaries(tabId: tabId).count == 2)
    }

    @Test("A shorter Query History window shortens the retention", arguments: [(7, 7), (90, 30), (0, 30)])
    func historyWindowCapsRetention(historyDays: Int, expected: Int) async {
        historyMaxDays.withLock { $0 = historyDays }
        #expect(storage.retentionDays == expected)

        await record("SELECT 1")
        advance(by: TimeInterval(expected) * 86_400 + 1)
        #expect(storage.summaries(tabId: tabId).isEmpty)
    }

    @Test("Idle snapshots within five minutes of the first become one version holding the latest text")
    func idleSnapshotsCoalesce() async throws {
        await record("SELECT 1", .idle)
        advance(by: 60)
        await record("SELECT 12", .idle)
        advance(by: 200)
        await record("SELECT 123", .idle)

        let summaries = storage.summaries(tabId: tabId)
        let only = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(only.reason == .idle)
        #expect(only.savedAt == Self.start.addingTimeInterval(260))
        #expect(texts() == ["SELECT 123"])
    }

    @Test("Steady typing still leaves a version every five minutes")
    func idleWindowCountsFromTheFirstSnapshot() async {
        await record("SELECT 1", .idle)
        for step in 2...4 {
            advance(by: 120)
            await record("SELECT \(step)", .idle)
        }
        #expect(texts() == ["SELECT 4", "SELECT 3"])
    }

    @Test("A run between idle snapshots keeps both sides of it")
    func runBreaksTheIdleWindow() async {
        await record("SELECT 1", .idle)
        advance(by: 10)
        await record("SELECT 2", .run)
        advance(by: 10)
        await record("SELECT 3", .idle)
        #expect(texts() == ["SELECT 3", "SELECT 2", "SELECT 1"])
        #expect(storage.summaries(tabId: tabId).map { $0.reason } == [.idle, .run, .idle])
    }

    @Test("A restore of the idle text seals it, so the next pause cannot overwrite it")
    func restoreSealsTheIdleVersion() async {
        await record("SELECT before", .idle)
        advance(by: 10)
        await record("SELECT before", .beforeRestore)
        advance(by: 10)
        await record("SELECT restored", .idle)
        #expect(texts() == ["SELECT restored", "SELECT before"])
        #expect(storage.summaries(tabId: tabId).map { $0.reason } == [.idle, .beforeRestore])
    }

    @Test("A coalesced pause takes the connection the tab moved to")
    func coalescedPauseFollowsTheConnection() async {
        let moved = UUID()
        await record("SELECT 1", .idle)
        advance(by: 10)
        _ = await storage.record(tabId: tabId, connectionId: moved, text: "SELECT 2", reason: .idle)
        #expect(await storage.removeVersions(forConnection: moved))
        #expect(storage.summaries(tabId: tabId).isEmpty)
    }

    @Test("A run, a replace and a restore always add a version")
    func otherReasonsAlwaysInsert() async {
        await record("SELECT 1", .run)
        await record("SELECT 2", .beforeReplace)
        await record("SELECT 3", .beforeRestore)
        #expect(storage.summaries(tabId: tabId).map { $0.reason } == [.beforeRestore, .beforeReplace, .run])
    }

    @Test("Deleting a connection removes its tabs' versions and leaves another's")
    func purgeByConnection() async {
        let otherTab = UUID()
        await record("SELECT 1")
        _ = await storage.record(tabId: otherTab, connectionId: UUID(), text: "SELECT kept", reason: .run)

        #expect(await storage.removeVersions(forConnection: connectionId))
        #expect(storage.summaries(tabId: tabId).isEmpty)
        #expect(texts(tab: otherTab) == ["SELECT kept"])
    }

    @Test("Clear History removes every version")
    func removeAllClearsEveryTab() async {
        let otherTab = UUID()
        await record("SELECT 1")
        await record("SELECT 2", tab: otherTab)

        #expect(await storage.removeAll())
        #expect(storage.summaries(tabId: tabId).isEmpty)
        #expect(storage.summaries(tabId: otherTab).isEmpty)
    }

    @Test("Each write is announced with its tab, and a purge with none")
    func writesAreAnnounced() async {
        await record("SELECT 1")
        await record("SELECT 1")
        await storage.removeAll()
        #expect(announced.withLock { $0 } == [tabId, nil])
    }

    @Test("A second store on the same file reads what the first wrote")
    func secondInstanceReadsTheRows() async throws {
        await record("SELECT 1")
        let second = reopenedStorage()

        let summary = try #require(second.summaries(tabId: tabId).first)
        #expect(second.version(id: summary.id, tabId: tabId)?.query == "SELECT 1")
        #expect(second.version(id: summary.id, tabId: UUID()) == nil)
    }

    @Test("Before the first write there is nothing to read and no file is made")
    func readBeforeAnyWriteIsEmpty() {
        #expect(storage.summaries(tabId: tabId).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
