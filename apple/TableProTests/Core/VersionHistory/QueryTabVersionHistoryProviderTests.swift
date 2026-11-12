//
//  QueryTabVersionHistoryProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class FakeQueryTab {
    let connectionId = UUID()
    var text: String?
    var isCapturePaused = false
    private(set) var writes: [String] = []
    private(set) var reasonsAtWrite: [[QueryTabVersionReason]] = []

    init(text: String?) {
        self.text = text
    }

    func write(_ newText: String, storage: QueryTabVersionStorage, tabId: UUID) -> Bool {
        guard text != nil else { return false }
        reasonsAtWrite.append(storage.summaries(tabId: tabId).map { $0.reason })
        writes.append(newText)
        text = newText
        return true
    }
}

@MainActor
struct QueryTabVersionHistoryProviderTests {
    private let storage = QueryTabVersionStorage(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("query_tab_provider_\(UUID().uuidString).db"),
        announce: { _ in },
        removeDatabaseOnDeinit: true
    )
    private let tabId = UUID()

    private func provider(for tab: FakeQueryTab) -> QueryTabVersionHistoryProvider {
        QueryTabVersionHistoryProvider(
            tabId: tabId,
            storage: storage,
            liveTab: { tab.text.map { LiveQueryTab(connectionId: tab.connectionId, text: $0) } },
            write: { tab.write($0, storage: storage, tabId: tabId) },
            isCapturePaused: { tab.isCapturePaused }
        )
    }

    private func recordPast(_ texts: [String], connectionId: UUID) async {
        for text in texts {
            await storage.record(tabId: tabId, connectionId: connectionId, text: text, reason: .run)
        }
    }

    @Test("The page is the current text, then each version newest first, with the retention notice")
    func pageListsCurrentThenNewestFirst() async throws {
        let tab = FakeQueryTab(text: "SELECT 3")
        await recordPast(["SELECT 1", "SELECT 2"], connectionId: tab.connectionId)

        let page = try await provider(for: tab).loadHistory()

        #expect(page.entries.count == 3)
        #expect(page.entries.first?.reference == .current)
        #expect(page.entries.dropFirst().allSatisfy { $0.summary == String(localized: "Run") })
        #expect(page.notice == .keepsRecentVersions(count: 50, days: storage.retentionDays))
        let newest = try #require(page.entries.dropFirst().first)
        #expect(try await provider(for: tab).content(of: newest.reference) == "SELECT 2")
    }

    @Test("The current entry reads the tab's live text")
    func currentContentIsTheLiveText() async throws {
        let tab = FakeQueryTab(text: "SELECT live")
        #expect(try await provider(for: tab).content(of: .current) == "SELECT live")
    }

    @Test("A version of another tab, or one that is gone, is not found")
    func foreignVersionIsNotFound() async throws {
        let tab = FakeQueryTab(text: "SELECT 1")
        let otherTab = UUID()
        await storage.record(tabId: otherTab, connectionId: tab.connectionId, text: "SELECT other", reason: .run)
        let otherId = try #require(storage.summaries(tabId: otherTab).first?.id)

        await #expect(throws: VersionHistoryError.versionNotFound) {
            try await provider(for: tab).content(of: .tabVersion(id: otherId))
        }
        await #expect(throws: VersionHistoryError.versionNotFound) {
            try await provider(for: tab).prepareRestore(.tabVersion(id: 999))
        }
    }

    @Test("Restore records the text it replaces first, then writes the version into the tab")
    func restoreRecordsThenWrites() async throws {
        let tab = FakeQueryTab(text: "SELECT 1")
        await recordPast(["SELECT 1"], connectionId: tab.connectionId)
        let version = try #require(storage.summaries(tabId: tabId).first)
        tab.text = "SELECT typed since"

        let plan = try await provider(for: tab).prepareRestore(.tabVersion(id: version.id))
        #expect(plan.replacesUncommittedChanges == false)
        try await plan.apply()

        #expect(tab.writes == ["SELECT 1"])
        #expect(tab.reasonsAtWrite == [[.beforeRestore, .run]])
        let replaced = try #require(storage.summaries(tabId: tabId).first)
        #expect(storage.version(id: replaced.id, tabId: tabId)?.query == "SELECT typed since")
    }

    @Test("With capture paused, restore writes the version and records nothing")
    func pausedRestoreRecordsNothing() async throws {
        let tab = FakeQueryTab(text: "SELECT 1")
        await recordPast(["SELECT 1"], connectionId: tab.connectionId)
        let version = try #require(storage.summaries(tabId: tabId).first)
        tab.text = "SELECT typed since"
        tab.isCapturePaused = true

        try await provider(for: tab).prepareRestore(.tabVersion(id: version.id)).apply()

        #expect(tab.writes == ["SELECT 1"])
        #expect(storage.summaries(tabId: tabId).map { $0.id } == [version.id])
    }

    @Test("A closed tab says so for its list, its text and a restore")
    func closedTabThrowsTabClosed() async throws {
        let tab = FakeQueryTab(text: nil)
        await recordPast(["SELECT 1"], connectionId: tab.connectionId)
        let version = try #require(storage.summaries(tabId: tabId).first)

        await #expect(throws: VersionHistoryError.tabClosed) { try await provider(for: tab).loadHistory() }
        await #expect(throws: VersionHistoryError.tabClosed) { try await provider(for: tab).content(of: .current) }
        await #expect(throws: VersionHistoryError.tabClosed) {
            try await provider(for: tab).prepareRestore(.tabVersion(id: version.id))
        }
        #expect(try await provider(for: tab).content(of: .tabVersion(id: version.id)) == "SELECT 1")
    }

    @Test("A tab that closes between prepare and apply is not written")
    func tabClosedBeforeApplyIsNotWritten() async throws {
        let tab = FakeQueryTab(text: "SELECT 2")
        await recordPast(["SELECT 1"], connectionId: tab.connectionId)
        let version = try #require(storage.summaries(tabId: tabId).first)
        let plan = try await provider(for: tab).prepareRestore(.tabVersion(id: version.id))
        tab.text = nil

        await #expect(throws: VersionHistoryError.tabClosed) { try await plan.apply() }
        #expect(tab.writes.isEmpty)
    }

    @Test("Each reason names its version, and an idle snapshot is titled by its date")
    func reasonSummaries() {
        #expect(QueryTabVersionReason.run.summary == String(localized: "Run"))
        #expect(QueryTabVersionReason.beforeReplace.summary == String(localized: "Before Replace"))
        #expect(QueryTabVersionReason.beforeRestore.summary == String(localized: "Before Restore"))
        #expect(QueryTabVersionReason.idle.summary == nil)
    }
}
