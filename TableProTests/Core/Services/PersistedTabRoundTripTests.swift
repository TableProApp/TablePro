//
//  PersistedTabRoundTripTests.swift
//  TableProTests
//
//  Tests that session-restore view state round-trips through PersistedTab.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("PersistedTab round-trip")
@MainActor
struct PersistedTabRoundTripTests {
    private func tableTab(query: String = "SELECT 1") -> QueryTab {
        QueryTab(id: UUID(), title: "Users", query: query, tabType: .table, tableName: "users")
    }

    @Test("Sort columns persist by name and restore as pending sort")
    func sortColumnsRoundTrip() {
        var tab = tableTab()
        tab.sortState = SortState(
            columns: [
                SortColumn(columnIndex: 0, direction: .descending, columnName: "created_at"),
                SortColumn(columnIndex: 2, direction: .ascending, columnName: "name")
            ],
            source: .user
        )

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        #expect(restored.pendingRestoredSort?.count == 2)
        #expect(restored.pendingRestoredSort?[0].columnName == "created_at")
        #expect(restored.pendingRestoredSort?[0].direction == .descending)
        #expect(restored.pendingRestoredSort?[1].columnName == "name")
        #expect(restored.pendingRestoredSort?[1].direction == .ascending)
    }

    @Test("Sort columns without a resolved name are dropped from persistence")
    func sortColumnsWithoutNameAreDropped() {
        var tab = tableTab()
        tab.sortState = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user)

        #expect(tab.toPersistedTab().sortColumns == nil)
    }

    @Test("Pagination page round-trips for table tabs")
    func paginationPageRoundTrip() {
        var tab = tableTab()
        tab.pagination.currentPage = 3

        let persisted = tab.toPersistedTab()
        #expect(persisted.restoredPage == 3)
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).restoredPage == 3)
    }

    @Test("Restored table tab seeds pagination from the live page size, not the persisted query")
    func paginationSeedsFromLivePageSize() {
        var tab = tableTab(query: "SELECT * FROM users LIMIT 500 OFFSET 0")
        tab.pagination.pageSize = 500

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        #expect(restored.pagination.pageSize == 1_000)
    }

    @Test("Page 1 is not persisted")
    func pageOneNotPersisted() {
        var tab = tableTab()
        tab.pagination.currentPage = 1

        #expect(tab.toPersistedTab().restoredPage == nil)
    }

    @Test("Cursor offset round-trips for query tabs")
    func cursorOffsetRoundTrip() {
        var tab = QueryTab(id: UUID(), title: "Q", query: "SELECT * FROM users", tabType: .query)
        tab.restoredCursorOffset = 7

        let persisted = tab.toPersistedTab()
        #expect(persisted.cursorOffset == 7)
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).restoredCursorOffset == 7)
    }

    @Test("Cursor offset is clamped to query length on restore")
    func cursorOffsetClampedToQueryLength() {
        let persisted = PersistedTab(
            id: UUID(),
            title: "Q",
            query: "SELECT",
            tabType: .query,
            tableName: nil,
            cursorOffset: 10_000
        )

        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).restoredCursorOffset == ("SELECT" as NSString).length)
    }

    @Test("A truncated query drops the persisted cursor offset")
    func cursorOffsetDroppedWhenQueryTruncated() {
        var tab = QueryTab(
            id: UUID(),
            title: "Q",
            query: String(repeating: "a", count: TabQueryContent.maxPersistableQuerySize + 1),
            tabType: .query
        )
        tab.restoredCursorOffset = 42

        let persisted = tab.toPersistedTab()
        #expect(persisted.query.isEmpty)
        #expect(persisted.cursorOffset == 0)
    }

    @Test("Column widths round-trip")
    func columnWidthsRoundTrip() {
        var tab = tableTab()
        tab.columnLayout.columnWidths = ["id": 80, "name": 220.5]

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        #expect(restored.columnLayout.columnWidths == ["id": 80, "name": 220.5])
    }

    @Test("erDiagramSchemaKey and queryParameters persist through toPersistedTab")
    func erDiagramAndParametersRoundTrip() {
        var tab = QueryTab(id: UUID(), title: "ER", query: "", tabType: .erDiagram)
        tab.display.erDiagramSchemaKey = "public"
        tab.content.queryParameters = [QueryParameter(name: "id", value: "1")]

        let persisted = tab.toPersistedTab()
        #expect(persisted.erDiagramSchemaKey == "public")
        #expect(persisted.queryParameters?.count == 1)
    }

    @Test("windowGroupIndex encodes and decodes")
    func windowGroupIndexRoundTrip() throws {
        let tab = tableTab().toPersistedTab(windowGroupIndex: 2)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)
        #expect(decoded.windowGroupIndex == 2)
    }

    @Test("SortDirection encodes as a stable string")
    func sortDirectionCodable() throws {
        for direction in [SortDirection.ascending, .descending] {
            let data = try JSONEncoder().encode(direction)
            #expect(try JSONDecoder().decode(SortDirection.self, from: data) == direction)
        }
    }

    @Test("Old persisted tabs without new fields decode with defaults")
    func oldFileWithoutNewFieldsDecodesGracefully() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Legacy","query":"SELECT 1","tabType":{"query":{}},"tableName":null}
        """
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: Data(json.utf8))
        #expect(decoded.sortColumns == nil)
        #expect(decoded.restoredPage == nil)
        #expect(decoded.cursorOffset == nil)
        #expect(decoded.columnWidths == nil)
        #expect(decoded.windowGroupIndex == nil)
        #expect(decoded.isView == false)
    }
}
