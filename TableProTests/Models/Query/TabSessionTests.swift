//
//  TabSessionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TabSession")
@MainActor
struct TabSessionTests {
    private func makeQueryTab(
        title: String = "Tab",
        query: String = "SELECT 1",
        tabType: TabType = .query,
        tableName: String? = nil
    ) -> QueryTab {
        QueryTab(title: title, query: query, tabType: tabType, tableName: tableName)
    }

    // MARK: - Initialization

    @Test("Init from QueryTab preserves id and all primitive fields")
    func initFromQueryTabPreservesIdentity() {
        var tab = makeQueryTab(title: "Users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.tableContext.databaseName = "main"
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date(timeIntervalSince1970: 1_000)
        tab.schemaVersion = 7

        let session = TabSession(queryTab: tab)

        #expect(session.id == tab.id)
        #expect(session.title == "Users")
        #expect(session.tabType == .table)
        #expect(session.content.query == "SELECT * FROM users")
        #expect(session.tableContext.tableName == "users")
        #expect(session.tableContext.databaseName == "main")
        #expect(session.tableContext.isEditable == true)
        #expect(session.execution.lastExecutedAt == Date(timeIntervalSince1970: 1_000))
        #expect(session.schemaVersion == 7)
    }

    @Test("Init with primitives produces same defaults as QueryTab.init")
    func initPrimitivesMatchesQueryTabDefaults() {
        let id = UUID()
        let session = TabSession(id: id, title: "Q", query: "x", tabType: .query, tableName: nil)
        let tab = QueryTab(id: id, title: "Q", query: "x", tabType: .query, tableName: nil)

        #expect(session.id == tab.id)
        #expect(session.title == tab.title)
        #expect(session.tabType == tab.tabType)
        #expect(session.content.query == tab.content.query)
        #expect(session.isPreview == tab.isPreview)
        #expect(session.schemaVersion == tab.schemaVersion)
        #expect(session.hasUserInteraction == tab.hasUserInteraction)
    }

    // MARK: - Conversion roundtrip

    @Test("snapshot() returns a QueryTab equal to the source")
    func snapshotRoundtripEqualsSource() {
        var original = makeQueryTab(title: "Orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders")
        original.tableContext.primaryKeyColumns = ["id"]
        original.execution.rowsAffected = 42
        original.pagination.currentPage = 3
        original.pagination.pageSize = 100
        original.sortState.columns = [SortColumn(columnIndex: 0, direction: .descending)]

        let session = TabSession(queryTab: original)
        let roundtrip = session.snapshot()

        #expect(roundtrip == original)
    }

    @Test("absorb() updates fields and preserves id")
    func absorbReplacesState() {
        let id = UUID()
        let initial = QueryTab(id: id, title: "v1", query: "SELECT 1", tabType: .query)
        let session = TabSession(queryTab: initial)

        var updated = QueryTab(id: id, title: "v2", query: "SELECT 2", tabType: .table, tableName: "users")
        updated.schemaVersion = 9

        session.absorb(updated)

        #expect(session.id == id)
        #expect(session.title == "v2")
        #expect(session.content.query == "SELECT 2")
        #expect(session.tabType == .table)
        #expect(session.tableContext.tableName == "users")
        #expect(session.schemaVersion == 9)
    }

    // MARK: - Reference semantics

    @Test("Multiple references see the same mutations (class semantics)")
    func sharedReferenceSemantics() {
        let session = TabSession(queryTab: makeQueryTab())
        let alias = session

        alias.title = "renamed"
        alias.schemaVersion = 5

        #expect(session.title == "renamed")
        #expect(session.schemaVersion == 5)
    }

    @Test("Snapshot decouples from the live session (value semantics on the snapshot)")
    func snapshotIsDecoupled() {
        let session = TabSession(queryTab: makeQueryTab(title: "live"))
        var taken = session.snapshot()

        taken.title = "snapshot-only"

        #expect(session.title == "live")
        #expect(taken.title == "snapshot-only")
    }

    // MARK: - Session-only state defaults

    @Test("tableRows defaults to an empty TableRows on primitive init")
    func tableRowsDefaultsEmptyOnPrimitiveInit() {
        let session = TabSession()
        #expect(session.tableRows.rows.isEmpty)
        #expect(session.tableRows.columns.isEmpty)
    }

    @Test("tableRows defaults to an empty TableRows when lifted from QueryTab")
    func tableRowsDefaultsEmptyFromQueryTab() {
        let session = TabSession(queryTab: makeQueryTab())
        #expect(session.tableRows.rows.isEmpty)
        #expect(session.tableRows.columns.isEmpty)
    }

    @Test("isEvicted defaults to false")
    func isEvictedDefaultsFalse() {
        #expect(TabSession().isEvicted == false)
        #expect(TabSession(queryTab: makeQueryTab()).isEvicted == false)
    }

    @Test("loadEpoch defaults to zero")
    func loadEpochDefaultsZero() {
        #expect(TabSession().loadEpoch == 0)
        #expect(TabSession(queryTab: makeQueryTab()).loadEpoch == 0)
    }

    // MARK: - loadEpoch round-trip

    @Test("loadEpoch round-trips through snapshot()")
    func loadEpochRoundTripsThroughSnapshot() {
        let session = TabSession(queryTab: makeQueryTab())
        session.loadEpoch = 7

        let snapshot = session.snapshot()

        #expect(snapshot.loadEpoch == 7)
    }

    @Test("loadEpoch round-trips through absorb()")
    func loadEpochRoundTripsThroughAbsorb() {
        let id = UUID()
        let initial = QueryTab(id: id)
        let session = TabSession(queryTab: initial)

        var updated = QueryTab(id: id)
        updated.loadEpoch = 12
        session.absorb(updated)

        #expect(session.loadEpoch == 12)
    }

    @Test("loadEpoch survives a snapshot/absorb roundtrip across sessions")
    func loadEpochSurvivesRoundtrip() {
        let id = UUID()
        let session1 = TabSession(queryTab: QueryTab(id: id))
        session1.loadEpoch = 3

        let snapshot = session1.snapshot()
        let session2 = TabSession(queryTab: snapshot)

        #expect(session2.loadEpoch == 3)
    }
}
