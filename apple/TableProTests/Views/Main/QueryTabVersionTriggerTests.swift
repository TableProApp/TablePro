//
//  QueryTabVersionTriggerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class CaptureSwitch {
    var isPaused = false
}

@MainActor
struct QueryTabVersionTriggerTests {
    private let storage = QueryTabVersionStorage(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("query_tab_triggers_\(UUID().uuidString).db"),
        announce: { _ in },
        removeDatabaseOnDeinit: true
    )
    private let capture = CaptureSwitch()

    // The draft-save clock never moves unless a case advances it, so no idle version lands mid-case.
    private func makeFixture(
        query: String = "SELECT 1",
        connection: DatabaseConnection = TestFixtures.makeConnection()
    ) -> (CoordinatorFixture, QueryTab, ManualClock) {
        let fixture = CoordinatorFixture(connection: connection)
        let clock = ManualClock()
        fixture.coordinator.draftSaveClock = clock
        fixture.coordinator.executionGate = AlwaysDenyGate()
        fixture.coordinator.openTabInNewWindow = { _ in }
        let capture = capture
        fixture.coordinator.tabVersions = QueryTabVersionRecorder(
            storage: storage,
            isCapturePaused: { capture.isPaused }
        )
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: query, tabType: .query))
        return (fixture, tab, clock)
    }

    private func versions(of tabId: UUID) -> [(reason: QueryTabVersionReason, text: String?)] {
        storage.summaries(tabId: tabId).map { ($0.reason, storage.version(id: $0.id, tabId: tabId)?.query) }
    }

    @Test("Running a query tab records its text")
    func runRecordsTheText() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT 1")

        fixture.coordinator.runQuery(viewport: .firstRow)

        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        let recorded = versions(of: tab.id)
        #expect(recorded.map { $0.reason } == [.run])
        #expect(recorded.first?.text == "SELECT 1")
    }

    @Test("Run All records the tab's text")
    func runAllRecordsTheText() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT 1; SELECT 2")

        fixture.coordinator.runAllStatements()

        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        #expect(versions(of: tab.id).first?.text == "SELECT 1; SELECT 2")
    }

    @Test("Clear Query keeps the text it removes as a version")
    func clearQueryRecordsTheReplacedText() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT long_draft FROM t")

        fixture.coordinator.clearSelectedQuery()

        #expect(fixture.tabManager.selectedTab?.content.query == "")
        #expect(!fixture.coordinator.toolbarState.hasQueryText)
        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        let recorded = versions(of: tab.id)
        #expect(recorded.first?.reason == .beforeReplace)
        #expect(recorded.first?.text == "SELECT long_draft FROM t")
    }

    @Test("Loading a query into the current tab keeps the text it replaces as a version")
    func loadIntoEditorRecordsTheReplacedText() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT typed")

        fixture.coordinator.loadQueryIntoEditor("SELECT * FROM users")

        #expect(fixture.tabManager.selectedTab?.content.query == "SELECT * FROM users")
        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        #expect(versions(of: tab.id).first?.reason == .beforeReplace)
        #expect(versions(of: tab.id).first?.text == "SELECT typed")
    }

    @Test("Inserting a saved query appends it and keeps the text before it")
    func insertFavoriteAppendsAndRecords() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT 1")

        fixture.coordinator.insertFavorite(SQLFavorite(name: "Users", query: "SELECT * FROM users"))

        #expect(fixture.tabManager.selectedTab?.content.query == "SELECT 1\n\nSELECT * FROM users")
        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        #expect(versions(of: tab.id).first?.text == "SELECT 1")
    }

    // Any window may record and save: the old first-coordinator check left a second window's typing unsaved for 30s.
    @Test("An idle pause records a version from a window that is not the connection's first")
    func idlePauseRecordsFromAnyWindow() async throws {
        let (fixture, tab, clock) = makeFixture(query: "SELECT draft")
        let firstWindow = CoordinatorFixture(connection: fixture.connection)
        firstWindow.coordinator.registerEagerly()
        #expect(MainContentCoordinator.activeCoordinators[fixture.coordinator.instanceId] == nil)

        fixture.coordinator.scheduleDraftSave(editedTab: tab.id)
        await clock.waitUntilSleeping()
        clock.advance(by: MainContentCoordinator.draftSaveDebounce)

        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        #expect(versions(of: tab.id).first?.reason == .idle)
        #expect(versions(of: tab.id).first?.text == "SELECT draft")
    }

    @Test("With Query History capture paused, nothing a tab runs or replaces is kept")
    func pausedCaptureRecordsNothing() async throws {
        let (fixture, tab, clock) = makeFixture(query: "SELECT secret")
        capture.isPaused = true

        fixture.coordinator.runQuery(viewport: .firstRow)
        fixture.coordinator.loadQueryIntoEditor("SELECT other")
        #expect(fixture.coordinator.tabVersions.record(tab, connectionId: fixture.connection.id, reason: .run) == nil)

        // A version recorded after the pause lifts is the only one, so nothing earlier was queued.
        capture.isPaused = false
        fixture.coordinator.scheduleDraftSave(editedTab: tab.id)
        await clock.waitUntilSleeping()
        clock.advance(by: MainContentCoordinator.draftSaveDebounce)
        try await waitUntil { !storage.summaries(tabId: tab.id).isEmpty }
        #expect(versions(of: tab.id).map { $0.reason } == [.idle])
        #expect(versions(of: tab.id).first?.text == "SELECT other")
    }

    @Test("Revert To writes the chosen version into the tab and keeps the text it replaced")
    func revertRestoresAndRecords() async throws {
        let (fixture, tab, _) = makeFixture(query: "SELECT first")
        await storage.record(tabId: tab.id, connectionId: fixture.connection.id, text: "SELECT first", reason: .run)
        let version = try #require(storage.summaries(tabId: tab.id).first)
        fixture.tabManager.mutate(tabId: tab.id) { $0.content.query = "SELECT second" }

        fixture.coordinator.revertQueryTab(tab.id, toVersion: version.id)

        try await waitUntil { fixture.tabManager.selectedTab?.content.query == "SELECT first" }
        #expect(versions(of: tab.id).first?.reason == .beforeRestore)
        #expect(versions(of: tab.id).first?.text == "SELECT second")
    }

    @Test("A table tab records nothing")
    func tableTabRecordsNothing() {
        let (fixture, _, _) = makeFixture()
        let table = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        #expect(fixture.coordinator.tabVersions.record(table, connectionId: fixture.connection.id, reason: .run) == nil)
    }
}
