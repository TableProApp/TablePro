//
//  SQLFileDeduplicationTests.swift
//  TableProTests
//
//  Tests for SQL file deduplication when opening .sql files in TablePro.
//  Validates sourceFileURL tracking on QueryTab, EditorTabPayload, and PersistedTab,
//  deduplication logic in QueryTabManager, and the lookup that finds a file's hosted tab.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// MARK: - QueryTab sourceFileURL Property Tests

struct QueryTabSourceFileURLTests {
    @Test("QueryTab stores sourceFileURL when set")
    func storesSourceFileURL() {
        var tab = QueryTab(title: "Test", tabType: .query)
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        tab.content.sourceFileURL = url

        #expect(tab.content.sourceFileURL == url)
    }

    @Test("QueryTab sourceFileURL defaults to nil")
    func defaultsToNil() {
        let tab = QueryTab(title: "Test", tabType: .query)

        #expect(tab.content.sourceFileURL == nil)
    }
}

// MARK: - QueryTabManager Deduplication Tests

struct QueryTabManagerDeduplicationTests {
    @Test("addTab with sourceFileURL creates new tab when no duplicate exists")
    @MainActor
    func createsNewTabWithSourceFileURL() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.content.sourceFileURL == url)
    }

    @Test("addTab with same sourceFileURL selects existing tab instead of creating duplicate")
    @MainActor
    func deduplicatesSameSourceFileURL() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.selectedTabId == tabManager.tabs.first?.id)
    }

    @Test("addTab with different sourceFileURL creates separate tabs")
    @MainActor
    func createsSeparateTabsForDifferentFiles() {
        let tabManager = QueryTabManager()
        let urlA = URL(fileURLWithPath: "/tmp/a.sql")
        let urlB = URL(fileURLWithPath: "/tmp/b.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: urlA)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: urlB)

        #expect(tabManager.tabs.count == 2)
    }

    @Test("addTab without sourceFileURL always creates new tab")
    @MainActor
    func noDedupWhenSourceFileURLIsNil() {
        let tabManager = QueryTabManager()

        tabManager.addTab(initialQuery: "SELECT 1")
        tabManager.addTab(initialQuery: "SELECT 2")

        #expect(tabManager.tabs.count == 2)
    }

    @Test("addTab with sourceFileURL updates query content of existing tab")
    @MainActor
    func updatesQueryContentOnDuplicate() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.content.query == "SELECT 2")
    }

    @Test("Reopening a file whose tab holds unsaved edits keeps them")
    @MainActor
    func keepsUnsavedEditsOnDuplicate() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.tabs[0].content.query = "SELECT 1 -- work in progress"

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.content.query == "SELECT 1 -- work in progress")
    }

    @Test("Reopening a clean file tab moves its saved baseline with the text")
    @MainActor
    func movesTheBaselineWithTheText() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.first?.content.savedFileContent == "SELECT 2")
        #expect(tabManager.tabs.first?.content.isFileDirty == false)
    }

    @Test("A tab that never learned what its file said is not overwritten either")
    @MainActor
    func keepsTextWhenTheBaselineIsUnknown() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        var reopened = QueryTab(title: "test.sql", query: "SELECT 1 -- work in progress")
        reopened.content.sourceFileURL = url
        tabManager.adoptTab(reopened)

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.content.query == "SELECT 1 -- work in progress")
    }

    @Test("Reopening a clean file tab clears a pending changed-on-disk banner")
    @MainActor
    func clearsTheExternalModificationBanner() {
        let tabManager = QueryTabManager()
        let url = URL(fileURLWithPath: "/tmp/test.sql")

        tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        tabManager.tabs[0].content.diskChange = .modified(
            FileStamp(modificationSeconds: 1, modificationNanoseconds: 0, size: 8, fileNumber: 1)
        )

        tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        #expect(tabManager.tabs.first?.content.diskChange == nil)
    }
}

// MARK: - EditorTabPayload sourceFileURL Tests

struct EditorTabPayloadSourceFileURLTests {
    @Test("EditorTabPayload carries sourceFileURL")
    func carriesSourceFileURL() {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            initialQuery: "SELECT 1",
            sourceFileURL: url
        )

        #expect(payload.sourceFileURL == url)
    }

    @Test("EditorTabPayload with sourceFileURL still has openContent intent by default")
    func sourceFileURLDoesNotChangeIntent() {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: UUID(),
            tabType: .query,
            sourceFileURL: url
        )

        #expect(payload.intent == .openContent)
    }
}

// MARK: - SessionStateFactory sourceFileURL Propagation Tests

struct SessionStateFactorySourceFileURLTests {
    @Test("SessionStateFactory propagates sourceFileURL to tab")
    @MainActor
    func propagatesSourceFileURL() {
        let conn = TestFixtures.makeConnection()
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let payload = EditorTabPayload(
            connectionId: conn.id,
            tabType: .query,
            initialQuery: "SELECT 1",
            sourceFileURL: url
        )

        let state = SessionStateFactory.create(connection: conn, payload: payload)

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.content.sourceFileURL == url)
    }
}

// MARK: - PersistedTab sourceFileURL Round-Trip Tests

struct PersistedTabSourceFileURLTests {
    @Test("PersistedTab preserves sourceFileURL through encode/decode")
    func roundTripsSourceFileURL() throws {
        let url = URL(fileURLWithPath: "/tmp/test.sql")
        let original = PersistedTab(
            id: UUID(),
            title: "Test",
            query: "SELECT 1",
            tabType: .query,
            tableName: nil,
            sourceFileURL: url
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(decoded.sourceFileURL == url)
    }

    @Test("PersistedTab without sourceFileURL decodes as nil")
    func decodesNilSourceFileURL() throws {
        let original = PersistedTab(
            id: UUID(),
            title: "Test",
            query: "SELECT 1",
            tabType: .query,
            tableName: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(decoded.sourceFileURL == nil)
    }
}

// MARK: - Hosted Source File Lookup Tests

@MainActor
struct HostedSourceFileLookupTests {
    private func makeCoordinator() -> MainContentCoordinator {
        SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil).coordinator
    }

    private func makeURL(_ name: String = "lookup") -> URL {
        URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString).sql")
    }

    private func routing(
        over coordinators: [MainContentCoordinator],
        reveal: @escaping (MainContentCoordinator, UUID) -> Bool = { _, _ in true }
    ) -> HostedTabRouting {
        HostedTabRouting(coordinators: { _ in [] }, reveal: reveal, allCoordinators: { coordinators })
    }

    @Test("Finds the tab holding a file on whichever hosted connection has it")
    func findsTheTabOnAnotherConnection() {
        let dev = makeCoordinator()
        let prod = makeCoordinator()
        defer {
            dev.teardown()
            prod.teardown()
        }
        let url = makeURL()
        dev.tabManager.addTab(initialQuery: "SELECT 1")
        prod.tabManager.addTab(initialQuery: "SELECT 2", sourceFileURL: url)

        let match = routing(over: [dev, prod]).tab(editing: url)

        #expect(match?.coordinator === prod)
        #expect(match?.tabId == prod.tabManager.tabs.first?.id)
    }

    @Test("Finds nothing when no hosted tab holds the file")
    func findsNothingForAFileNoTabHolds() {
        let dev = makeCoordinator()
        defer { dev.teardown() }
        dev.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: makeURL("other"))

        #expect(routing(over: [dev]).tab(editing: makeURL())?.tabId == nil)
    }

    @Test("A file tab the user closed is not found again")
    func closedTabIsNotFound() {
        let dev = makeCoordinator()
        defer { dev.teardown() }
        let url = makeURL()
        dev.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        guard let id = dev.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }

        dev.closeTabsByUser(ids: [id])

        #expect(routing(over: [dev]).tab(editing: url)?.tabId == nil)
    }

    @Test("A tab saved under another name is found by its new file only")
    func renamedFileIsFoundUnderItsNewURL() {
        let dev = makeCoordinator()
        defer { dev.teardown() }
        let original = makeURL("original")
        let renamed = makeURL("renamed")
        dev.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: original)
        guard let id = dev.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }

        dev.tabManager.mutate(tabId: id) { $0.content.sourceFileURL = renamed }

        let lookup = routing(over: [dev])
        #expect(lookup.tab(editing: original)?.tabId == nil)
        #expect(lookup.tab(editing: renamed)?.tabId == id)
    }

    @Test("Revealing a file's tab hands its own coordinator and tab to the reveal")
    func revealGoesToTheOwningCoordinator() {
        let dev = makeCoordinator()
        let prod = makeCoordinator()
        defer {
            dev.teardown()
            prod.teardown()
        }
        let url = makeURL()
        prod.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        var revealedConnection: UUID?
        var revealedTab: UUID?
        let lookup = routing(over: [dev, prod]) { coordinator, tabId in
            revealedConnection = coordinator.connectionId
            revealedTab = tabId
            return true
        }

        #expect(lookup.revealTab(editing: url))
        #expect(revealedConnection == prod.connectionId)
        #expect(revealedTab == prod.tabManager.tabs.first?.id)
    }

    @Test("A reveal that fails reports the file as not shown")
    func failedRevealReportsFalse() {
        let dev = makeCoordinator()
        defer { dev.teardown() }
        let url = makeURL()
        dev.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)

        let lookup = routing(over: [dev]) { _, _ in false }

        #expect(!lookup.revealTab(editing: url))
    }

    @Test("A linked favorite open on another connection is revealed there, not opened again here")
    func linkedFavoriteRevealsTheTabOnAnotherConnection() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-source-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("report.sql")
        try "SELECT 1".write(to: url, atomically: true, encoding: .utf8)

        let dev = makeCoordinator()
        let prod = makeCoordinator()
        defer {
            dev.teardown()
            prod.teardown()
        }
        prod.tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: url)
        dev.tabManager.addTab(initialQuery: "")
        var revealedTab: UUID?
        dev.hostedTabRouting = routing(over: [dev, prod]) { _, tabId in
            revealedTab = tabId
            return true
        }
        let favorite = LinkedSQLFavorite(
            folderId: UUID(),
            fileURL: url,
            relativePath: "report.sql",
            name: "report",
            mtime: Date(),
            fileSize: 8
        )

        dev.openLinkedFavorite(favorite)

        #expect(revealedTab == prod.tabManager.tabs.first?.id)
        #expect(dev.tabManager.tabs.allSatisfy { $0.content.sourceFileURL == nil })
    }
}
