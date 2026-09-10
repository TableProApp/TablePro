//
//  PersistedTabRoundTripTests.swift
//  TableProTests
//
//  Tests that session-restore view state round-trips through PersistedTab.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private struct LegacyPersistedTabWidths: Decodable {
    let columnWidths: [String: CGFloat]?
}

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

    // MARK: - A tab that is restored but never selected

    /// Only the selected tab runs the first load that consumes the pending sort and page, but every
    /// save maps every tab through toPersistedTab. Re-deriving from live state wrote nil for the
    /// others, so their sort and page were gone by the third launch without the user touching them.
    @Test("An unactivated tab re-emits the sort it has not consumed yet")
    func unconsumedSortSurvivesResave() {
        var tab = tableTab()
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .descending, columnName: "created_at")],
            source: .user
        )

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        let resaved = restored.toPersistedTab()

        #expect(resaved.sortColumns?.count == 1)
        #expect(resaved.sortColumns?[0].columnName == "created_at")
        #expect(resaved.sortColumns?[0].direction == .descending)
    }

    @Test("An unactivated tab re-emits the page it has not consumed yet")
    func unconsumedPageSurvivesResave() {
        var tab = tableTab()
        tab.pagination.currentPage = 7

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        let resaved = restored.toPersistedTab()

        #expect(resaved.restoredPage == 7)
    }

    @Test("Repeated saves without activation keep the state indefinitely")
    func stateSurvivesRepeatedResaves() {
        var tab = tableTab()
        tab.pagination.currentPage = 4
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")],
            source: .user
        )

        var persisted = tab.toPersistedTab()
        for _ in 0..<3 {
            persisted = QueryTab(from: persisted, defaultPageSize: 1_000).toPersistedTab()
        }

        #expect(persisted.restoredPage == 4)
        #expect(persisted.sortColumns?[0].columnName == "id")
    }

    // MARK: - The page size the page index was counted in

    /// A page index means nothing on its own: the offset is recomputed as (page - 1) * pageSize.
    /// Reading a page counted in 50s as pages of 1000 lands the tab on rows it never showed.
    @Test("A persisted page carries the page size it was counted in")
    func persistedPageCarriesItsPageSize() {
        var tab = tableTab()
        tab.pagination.pageSize = 50
        tab.pagination.currentPage = 20

        let persisted = tab.toPersistedTab()

        #expect(persisted.restoredPage == 20)
        #expect(persisted.restoredPageSize == 50)
        #expect(QueryTab(from: persisted, defaultPageSize: 1_000).restoredPageSize == 50)
    }

    @Test("Page 1 carries no page size, so Show All never restores a huge page")
    func pageOneCarriesNoPageSize() {
        var tab = tableTab()
        tab.pagination.pageSize = 5_000_000
        tab.pagination.currentPage = 1

        let persisted = tab.toPersistedTab()

        #expect(persisted.restoredPage == nil)
        #expect(persisted.restoredPageSize == nil)
    }

    @Test("An unactivated tab re-emits its page size along with its page")
    func unconsumedPageSizeSurvivesResave() {
        var tab = tableTab()
        tab.pagination.pageSize = 50
        tab.pagination.currentPage = 20

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        let resaved = restored.toPersistedTab()

        #expect(resaved.restoredPage == 20)
        #expect(resaved.restoredPageSize == 50)
    }

    // MARK: - The fallback must not outlive the restore it stands in for

    /// The pending values stand in for a restore that has not happened yet. Once the tab has run,
    /// the live state is the truth, or a page the user has since left would be pinned forever with
    /// nothing able to correct it.
    @Test("Once the tab has run, live state wins over an unconsumed page")
    func executedTabPrefersLiveState() {
        var tab = tableTab()
        tab.pagination.currentPage = 12
        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)

        var paged = restored
        paged.execution.lastExecutedAt = Date()
        paged.pagination.currentPage = 1

        #expect(paged.restoredPage == 12)
        #expect(paged.toPersistedTab().restoredPage == nil)
    }

    @Test("Once the tab has run, clearing the sort clears it in persistence too")
    func executedTabDropsUnconsumedSort() {
        var tab = tableTab()
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")],
            source: .user
        )
        var restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        restored.execution.lastExecutedAt = Date()

        #expect(restored.toPersistedTab().sortColumns == nil)
    }

    /// Consumption is gated on table tabs, so a query tab would never clear a pending sort and it
    /// would reappear in the persisted record after the user cleared it.
    @Test("A query tab does not carry a pending sort forward")
    func queryTabDropsPendingSort() {
        var tab = tableTab()
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")],
            source: .user
        )
        var restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        restored.tabType = .query

        #expect(restored.toPersistedTab().sortColumns == nil)
    }

    /// Clamping the size alone moves the tab, because the page number counts pages of the size it
    /// was taken in. Page 2 of 5,000,000 starts at row 5,000,001; page 2 of the clamped 100,000
    /// starts at row 100,001, which is 4,900,000 rows short of what the tab was showing.
    @Test("A restored page size outside the supported range is clamped, and its page rescaled")
    func restoredPageSizeIsClamped() {
        let absurd = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users",
            restoredPage: 2,
            restoredPageSize: 5_000_000
        )

        let restored = QueryTab(from: absurd, defaultPageSize: 1_000)

        let clamped = SettingsValidationRules.defaultPageSizeRange.upperBound
        #expect(restored.restoredPageSize == clamped)
        #expect(restored.restoredPage == 5_000_000 / clamped + 1)
    }

    @Test("A page size below the supported range rescales its page too")
    func restoredPageBelowRangeIsRescaled() {
        let tiny = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users",
            restoredPage: 4,
            restoredPageSize: 5
        )

        let restored = QueryTab(from: tiny, defaultPageSize: 1_000)

        /// Page 4 of 5 rows starts at row 16. Clamped to 10 rows a page, row 16 is on page 2, so
        /// the tab opens on rows 11 to 20 rather than on 31 to 40.
        #expect(restored.restoredPageSize == SettingsValidationRules.defaultPageSizeRange.lowerBound)
        #expect(restored.restoredPage == 2)
    }

    /// A size the clamp leaves alone must leave the page alone too.
    @Test("A restored page size inside the supported range keeps its page")
    func restoredPageSurvivesAnUnclampedSize() {
        let saved = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users",
            restoredPage: 12,
            restoredPageSize: 100
        )

        let restored = QueryTab(from: saved, defaultPageSize: 1_000)

        #expect(restored.restoredPageSize == 100)
        #expect(restored.restoredPage == 12)
    }

    /// Both numbers come off disk, so nothing stops their product overflowing. A position that
    /// cannot be computed opens at the start rather than somewhere arbitrary.
    @Test("A restored position that cannot be computed opens at the first page")
    func restoredPageOverflowFallsBackToTheStart() {
        let corrupt = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users",
            restoredPage: Int.max,
            restoredPageSize: Int.max
        )

        let restored = QueryTab(from: corrupt, defaultPageSize: 1_000)

        #expect(restored.restoredPage == 1)
    }

    @Test("A tab saved before page sizes were persisted still restores its page")
    func legacyTabWithoutPageSizeStillRestores() {
        let legacy = PersistedTab(
            id: UUID(),
            title: "users",
            query: "SELECT * FROM users",
            tabType: .table,
            tableName: "users",
            restoredPage: 3
        )

        let restored = QueryTab(from: legacy, defaultPageSize: 1_000)

        #expect(restored.restoredPage == 3)
        #expect(restored.restoredPageSize == nil)
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

    @Test("A query past the inline size limit keeps its text and its cursor offset")
    func largeQueryKeepsTextAndCursorOffset() {
        let query = String(repeating: "a", count: TabQueryContent.maxPersistableQuerySize + 1)
        var tab = QueryTab(id: UUID(), title: "Q", query: query, tabType: .query)
        tab.restoredCursorOffset = 42

        let persisted = tab.toPersistedTab()
        #expect(persisted.query == query)
        #expect(persisted.cursorOffset == 42)
    }

    @Test("A selection round-trips, not just the caret")
    func cursorSelectionRoundTrip() {
        var tab = QueryTab(id: UUID(), title: "Q", query: "SELECT * FROM users", tabType: .query)
        tab.restoredCursorOffset = 7
        tab.restoredCursorLength = 5

        let persisted = tab.toPersistedTab()
        #expect(persisted.cursorOffset == 7)
        #expect(persisted.cursorLength == 5)
        let restored = QueryTab(from: persisted, defaultPageSize: 1_000)
        #expect(restored.restoredCursorOffset == 7)
        #expect(restored.restoredCursorLength == 5)
    }

    @Test("A selection that runs past a now-shorter query is trimmed, not dropped")
    func cursorSelectionClampedToQueryLength() {
        let persisted = PersistedTab(
            id: UUID(),
            title: "Q",
            query: "SELECT",
            tabType: .query,
            tableName: nil,
            cursorOffset: 3,
            cursorLength: 10_000
        )

        let restored = QueryTab(from: persisted, defaultPageSize: 1_000)
        #expect(restored.restoredCursorOffset == 3)
        #expect(restored.restoredCursorLength == ("SELECT" as NSString).length - 3)
    }

    @Test("A caret with no selection persists no length")
    func caretPersistsNoLength() {
        var tab = QueryTab(id: UUID(), title: "Q", query: "SELECT 1", tabType: .query)
        tab.restoredCursorOffset = 4
        tab.restoredCursorLength = 0

        #expect(tab.toPersistedTab().cursorLength == nil)
    }

    @Test("Column widths round-trip")
    func columnWidthsRoundTrip() {
        var tab = tableTab()
        tab.columnLayout.columnWidths = ["id": 80, "name": 220.5]

        let restored = QueryTab(from: tab.toPersistedTab(), defaultPageSize: 1_000)
        #expect(restored.columnLayout.columnWidths == ["id": 80, "name": 220.5])
    }

    @Test("Content widths round-trip while legacy tab readers keep total widths")
    func columnContentWidthsRoundTrip() throws {
        var tab = tableTab()
        tab.columnLayout.columnWidths = ["created_at": 176]
        tab.columnLayout.columnContentWidths = ["created_at": 160]

        let persisted = tab.toPersistedTab()
        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: encoded)
        let legacyDecoded = try JSONDecoder().decode(LegacyPersistedTabWidths.self, from: encoded)
        let restored = QueryTab(from: decoded, defaultPageSize: 1_000)

        #expect(restored.columnLayout.columnWidths == ["created_at": 176])
        #expect(restored.columnLayout.columnContentWidths == ["created_at": 160])
        #expect(legacyDecoded.columnWidths == ["created_at": 176])
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
        var tab = tableTab().toPersistedTab()
        tab.windowGroupIndex = 2
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
        #expect(decoded.columnContentWidths == nil)
        #expect(decoded.windowGroupIndex == nil)
        #expect(decoded.isView == false)
    }

    @Test("A persisted tab without a title key decodes to the default title, never empty")
    func missingTitleDecodesToDefault() throws {
        let json = """
        {"id":"\(UUID().uuidString)","query":"SELECT 1","tabType":{"query":{}},"tableName":null}
        """
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: Data(json.utf8))
        #expect(decoded.title == "Query")
    }

    @Test("A persisted tab with a null title decodes to the default title, never empty")
    func nullTitleDecodesToDefault() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":null,"query":"SELECT 1","tabType":{"query":{}},"tableName":null}
        """
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: Data(json.utf8))
        #expect(decoded.title == "Query")
    }

    @Test("A persisted tab with a real title keeps it")
    func realTitleIsPreserved() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"auth.users","query":"","tabType":{"query":{}},"tableName":null}
        """
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: Data(json.utf8))
        #expect(decoded.title == "auth.users")
    }

    /// The viewer tab is addressing only: it persists what identifies the object and refetches the
    /// source on restore. An overload's identity has to survive, or a restored tab reopens whichever
    /// routine shares its name.
    @Test("An object source tab round-trips the reference that identifies its object")
    func objectSourceTabRoundTripsItsReference() throws {
        let objectRef = DatabaseObjectRef(
            kind: .function,
            name: "transform",
            database: "shop",
            schema: "public",
            identity: "16401",
            argumentSignature: "(geometry, integer)",
            attributes: [ObjectAttribute(label: "Volatility", value: "IMMUTABLE")]
        )
        let tab = PersistedTab(
            id: UUID(),
            title: "Function: public.transform(geometry, integer)",
            query: "",
            tabType: .objectSource,
            tableName: nil,
            databaseName: "shop",
            schemaName: "public",
            objectRef: objectRef
        )

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(PersistedTab.self, from: data)

        #expect(decoded.tabType == .objectSource)
        #expect(decoded.objectRef == objectRef)
        #expect(decoded.objectRef?.identity == "16401")
        #expect(decoded.objectRef?.displayIdentity == "public.transform(geometry, integer)")
    }

    /// The source itself is never persisted, so a restored tab shows the definition as it is now
    /// rather than the copy that was on screen at quit.
    @Test("An object source tab persists no source text")
    func objectSourceTabPersistsNoSource() throws {
        let tab = PersistedTab(
            id: UUID(),
            title: "Trigger: audit",
            query: "",
            tabType: .objectSource,
            tableName: nil,
            objectRef: DatabaseObjectRef(
                kind: .trigger, name: "audit", database: "shop", schema: "public", table: "orders"
            )
        )
        let json = String(decoding: try JSONEncoder().encode(tab), as: UTF8.self)
        #expect(!json.contains("CREATE"))
        #expect(json.contains("orders"))
    }
}
