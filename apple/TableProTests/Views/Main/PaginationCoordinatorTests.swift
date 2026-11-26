//
//  PaginationCoordinatorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct PaginationCoordinatorTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator(
        pagination: PaginationState,
        loadedRowCount: Int
    ) -> (MainContentCoordinator, QueryTabManager, UUID) {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table)
        tab.tableContext.tableName = "users"
        tab.pagination = pagination
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let columns = ["id", "name"]
        let rows = (0..<loadedRowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(
            queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)

        return (coordinator, tabManager, tab.id)
    }

    private func pagination(_ tabManager: QueryTabManager, _ tabId: UUID) -> PaginationState? {
        tabManager.tabs.first { $0.id == tabId }?.pagination
    }

    /// The indicator has its own owner rather than riding on the row-count task slot, because every
    /// page turn launches an automatic count that takes that slot over.
    @Test("A count cancelled by a page turn still clears its own indicator")
    func cancelledCountClearsItsIndicator() {
        let (coordinator, _, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        let exactCount = UUID()
        coordinator.claimExactCount(for: tabId, token: exactCount)
        coordinator.setRowCountTask(Task {}, token: UUID(), for: tabId)

        #expect(coordinator.releaseExactCount(for: tabId, token: exactCount))
    }

    @Test("A superseded count cannot stop its successor's indicator")
    func supersededCountLeavesTheIndicatorAlone() {
        let (coordinator, _, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        let first = UUID()
        coordinator.claimExactCount(for: tabId, token: first)
        coordinator.releaseExactCount(for: tabId)

        let second = UUID()
        coordinator.claimExactCount(for: tabId, token: second)

        #expect(!coordinator.releaseExactCount(for: tabId, token: first))
        #expect(coordinator.releaseExactCount(for: tabId, token: second))
    }

    @Test("Go to page jumps to the requested page when total is known")
    func goToPageWithKnownTotal() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: 100, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        coordinator.goToPage(3)
        #expect(pagination(tabManager, tabId)?.currentPage == 3)
        #expect(pagination(tabManager, tabId)?.currentOffset == 20)
    }

    @Test("Go to page is ignored when total is unknown")
    func goToPageIgnoredWhenTotalUnknown() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 10, currentPage: 1),
            loadedRowCount: 10
        )
        coordinator.goToPage(3)
        #expect(pagination(tabManager, tabId)?.currentPage == 1)
    }

    @Test("Next page advances on an unknown total when a full page is loaded")
    func nextPageAdvancesUnknownTotalFullPage() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 5, currentPage: 1),
            loadedRowCount: 5
        )
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 2)
        #expect(pagination(tabManager, tabId)?.currentOffset == 5)
    }

    @Test("Next page does nothing on an unknown total when a partial page is loaded")
    func nextPageNoOpUnknownTotalPartialPage() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 10, currentPage: 1),
            loadedRowCount: 4
        )
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 1)
    }

    @Test("Last page is ignored when total is unknown")
    func lastPageIgnoredWhenTotalUnknown() {
        let (coordinator, tabManager, tabId) = makeCoordinator(
            pagination: PaginationState(totalRowCount: nil, pageSize: 5, currentPage: 2, currentOffset: 5),
            loadedRowCount: 5
        )
        coordinator.goToLastPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 2)
    }

    // A table keyed on `id`, shown in the app's default key order, page `page` of 10-row pages over 100 rows.
    private func makeKeyedCoordinator(
        page: Int,
        keyed: Bool = true,
        sortSource: SortSource = .defaultSort,
        type: DatabaseType = .mysql,
        keyIsNullable: Bool = false,
        masksKey: Bool = false,
        pageHasLanded: Bool = true
    ) -> (MainContentCoordinator, QueryTabManager, UUID) {
        let fixture = fixtures.make(connection: TestFixtures.makeConnection(type: type))
        let pageQuery = "SELECT * FROM `users` -- page \(page)"
        var tab = QueryTab(title: "users", query: pageQuery, tabType: .table)
        tab.tableContext.tableName = "users"
        if keyed { tab.tableContext.primaryKeyColumns = ["id"] }
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: "id")], source: sortSource
        )
        tab.pagination = PaginationState(
            totalRowCount: 100, pageSize: 10, currentPage: page, currentOffset: (page - 1) * 10
        )
        tab.execution.lastExecutedAt = Date()
        fixture.tabManager.tabs.append(tab)
        fixture.tabManager.selectedTabId = tab.id
        let first = (page - 1) * 10 + 1
        var tableRows = TableRows.from(
            queryRows: (first..<(first + 10)).map { [PluginCellValue.text(String($0)), .text("user \($0)")] },
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR(64)")]
        )
        tableRows.columnNullable = ["id": keyIsNullable, "name": true]
        if masksKey { _ = tableRows.addMasks(ColumnMasks(styles: [0: .hash])) }
        let shown = ResultSet(label: "users", tableRows: tableRows)
        shown.baseQuery = pageHasLanded ? pageQuery : "SELECT * FROM `users` -- the page before"
        fixture.tabManager.mutate(tabId: tab.id) { $0.display.replaceUnpinnedResults(with: [shown]) }
        fixture.coordinator.setActiveTableRows(tableRows, for: tab.id)
        return (fixture.coordinator, fixture.tabManager, tab.id)
    }

    private func query(_ tabManager: QueryTabManager, _ tabId: UUID) -> String? {
        tabManager.tabs.first { $0.id == tabId }?.content.query
    }

    @Test("Next page in key order seeks past the last row on screen")
    func nextPageSeeksPastTheLastKey() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3)
        coordinator.goToNextPage()
        let state = pagination(tabManager, tabId)
        #expect(state?.currentPage == 4)
        #expect(state?.currentOffset == 30)
        let built = "SELECT * FROM `users` WHERE `id` > 30 ORDER BY `id` ASC LIMIT 10 OFFSET 0"
        #expect(query(tabManager, tabId) == built)
        #expect(state?.keyedPage == KeyedPageRead(query: built, readsBackward: false))
        // The read the move started spent it.
        #expect(state?.seek == nil)
    }

    @Test("A user's sort on the key seeks too")
    func userSortOnTheKeySeeks() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3, sortSource: .user)
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.keyedPage?.query.contains("`id` > 30") == true)
    }

    @Test("Previous page reads backward from the first row, and that statement alone is flipped")
    func previousPageReadsBackward() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 4)
        coordinator.goToPreviousPage()
        let built = "SELECT * FROM `users` WHERE `id` < 31 ORDER BY `id` DESC LIMIT 10 OFFSET 0"
        #expect(pagination(tabManager, tabId)?.currentPage == 3)
        #expect(query(tabManager, tabId) == built)
        #expect(pagination(tabManager, tabId)?.keyedPage == KeyedPageRead(query: built, readsBackward: true))
    }

    @Test("Back to page 1 reads from the start")
    func previousToFirstPageReadsFromTheStart() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 2)
        coordinator.goToPreviousPage()
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 0")
    }

    @Test("Last page reads the tail backward instead of skipping every row before it")
    func lastPageReadsTheTail() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 2)
        coordinator.goToLastPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 10)
        #expect(pagination(tabManager, tabId)?.currentOffset == 90)
        #expect(query(tabManager, tabId) == "SELECT * FROM `users` ORDER BY `id` DESC LIMIT 10 OFFSET 0")
    }

    @Test("A jump to a page in the middle, and a table with no key, keep the offset")
    func jumpsAndUnkeyedTablesKeepTheOffset() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 2)
        coordinator.goToPage(6)
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 50")

        let (unkeyed, unkeyedTabs, unkeyedId) = makeKeyedCoordinator(page: 3, keyed: false)
        unkeyed.goToNextPage()
        #expect(pagination(unkeyedTabs, unkeyedId)?.keyedPage == nil)
        #expect(query(unkeyedTabs, unkeyedId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 30")
    }

    // Redshift accepts two rows with one primary key, and a seek past one of them would skip the other.
    @Test("An engine that does not enforce its keys keeps the offset")
    func unenforcedKeysKeepTheOffset() throws {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3, type: .redshift)
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 4)
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        let built = try #require(query(tabManager, tabId))
        #expect(built.hasSuffix("LIMIT 10 OFFSET 30"))
        #expect(!built.contains("WHERE"))
    }

    // SQLite takes NULL in a primary key that is not its rowid, and a seek passes over every NULL key.
    @Test("A key the catalog says can hold NULL keeps the offset, unless it is a lone INTEGER rowid")
    func nullableKeyKeepsTheOffset() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3, type: .sqlite, keyIsNullable: true)
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId)?.hasSuffix("LIMIT 10 OFFSET 30") == true)

        var rows = TableRows.from(queryRows: [], columns: ["id"], columnTypes: [.integer(rawType: "INTEGER")])
        rows.columnNullable = ["id": true]
        #expect(!MainContentCoordinator.keyHoldsNoNull(["id"], in: rows))
        rows.columnDeclaredTypes = ["id": "integer"]
        #expect(MainContentCoordinator.keyHoldsNoNull(["id"], in: rows))
        #expect(!MainContentCoordinator.keyHoldsNoNull(["id", "name"], in: rows))
    }

    // Next held down repeats before the page it asked for lands, and a stopped or failed load leaves the page before.
    @Test("Rows on screen from another page's statement keep the offset")
    func rowsOfAnotherPageKeepTheOffset() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3, pageHasLanded: false)
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.currentPage == 4)
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId)?.hasSuffix("LIMIT 10 OFFSET 30") == true)
    }

    @Test("A masked key keeps the offset, since its cells hold the mask's text")
    func maskedKeyKeepsTheOffset() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 3, masksKey: true)
        coordinator.goToNextPage()
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId)?.hasSuffix("LIMIT 10 OFFSET 30") == true)
    }

    @Test("Reading the page again, after a save, a refresh or a return to a stale tab, reads it at its offset")
    func rereadReadsAtTheOffset() {
        let (coordinator, tabManager, tabId) = makeKeyedCoordinator(page: 4)
        coordinator.goToPreviousPage()
        #expect(pagination(tabManager, tabId)?.keyedPage?.readsBackward == true)
        coordinator.stopExecution(for: tabId)
        coordinator.reloadActiveResult(onTab: tabId)
        #expect(pagination(tabManager, tabId)?.keyedPage == nil)
        #expect(query(tabManager, tabId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 20")

        let (refreshed, refreshedTabs, refreshedId) = makeKeyedCoordinator(page: 4)
        refreshed.goToNextPage()
        refreshed.reloadTableTab(refreshedId)
        #expect(pagination(refreshedTabs, refreshedId)?.keyedPage == nil)
        #expect(query(refreshedTabs, refreshedId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 40")

        let (stale, staleTabs, staleId) = makeKeyedCoordinator(page: 4)
        stale.goToNextPage()
        stale.rebuildTableQuery(forTab: staleId)
        #expect(query(staleTabs, staleId) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 40")
    }

    @Test("A page read backward is put back in key order with its row marks")
    func reversingRowsKeepsMarks() {
        var fetched = QueryFetchResult(
            columns: ["id"], columnTypes: [.integer(rawType: "INT")], rows: [["3"], ["2"], ["1"]],
            executionTime: 0, rowsAffected: 0, statusMessage: nil, isTruncated: false, resultColumnMeta: nil,
            rowLocators: ["c", "b", "a"], absentCells: [0: [0]]
        )
        fetched.unloadedCells = [2: [0: 10]]
        let page = fetched.reversingRows()
        #expect(page.rows == [["1"], ["2"], ["3"]])
        #expect(page.rowLocators == ["a", "b", "c"])
        #expect(page.absentCells == [2: [0]])
        #expect(page.unloadedCells == [0: [0: 10]])
    }
}

