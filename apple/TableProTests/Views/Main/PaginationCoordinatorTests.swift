//
//  PaginationCoordinatorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTestSupport
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

    // A table keyed on `id`, shown in the app's default key order, page `page` of 10-row pages over 100 rows. The
    // driver records what each read sends and answers whether the key names one row.
    private func makeKeyedPage(
        page: Int,
        keyed: Bool = true,
        sortSource: SortSource = .defaultSort,
        type: DatabaseType = .mysql,
        keyIsNullable: Bool = false,
        masksKey: Bool = false,
        pageHasLanded: Bool = true,
        keyNamesOneRow: Bool = true,
        columns: [String] = ["id", "name"],
        idType: ColumnType = .integer(rawType: "INT"),
        idText: (Int) -> String = { String($0) }
    ) -> KeyedPage {
        let connection = TestFixtures.makeConnection(type: type)
        let driver = PageRecordingDriver(connection: connection, keyNamesOneRow: keyNamesOneRow)
        let fixture = fixtures.make(connection: connection, driver: driver)
        let pageQuery = "SELECT * FROM `users` -- page \(page)"
        var tab = QueryTab(title: "users", query: pageQuery, tabType: .table)
        tab.tableContext.tableName = "users"
        if keyed { tab.tableContext.primaryKeyColumns = [columns[0]] }
        tab.sortState = SortState(
            columns: [SortColumn(columnIndex: 0, direction: .ascending, columnName: columns[0])], source: sortSource
        )
        tab.pagination = PaginationState(
            totalRowCount: 100, pageSize: 10, currentPage: page, currentOffset: (page - 1) * 10
        )
        tab.execution.lastExecutedAt = Date()
        fixture.tabManager.tabs.append(tab)
        fixture.tabManager.selectedTabId = tab.id
        if let scope = fixture.coordinator.scope(for: tab) {
            MetadataConnectionPool.shared.injectEntry(driver, scope: scope)
        }
        let first = (page - 1) * 10 + 1
        var tableRows = TableRows.from(
            queryRows: (first..<(first + 10)).map { [PluginCellValue.text(idText($0)), .text("user \($0)")] },
            columns: columns,
            columnTypes: [idType, .text(rawType: "VARCHAR(64)")]
        )
        tableRows.columnNullable = [columns[0]: keyIsNullable, columns[1]: true]
        if masksKey { _ = tableRows.addMasks(ColumnMasks(styles: [0: .hash])) }
        let shown = ResultSet(label: "users", tableRows: tableRows)
        shown.baseQuery = pageHasLanded ? pageQuery : "SELECT * FROM `users` -- the page before"
        fixture.tabManager.mutate(tabId: tab.id) { $0.display.replaceUnpinnedResults(with: [shown]) }
        fixture.coordinator.setActiveTableRows(tableRows, for: tab.id)
        return KeyedPage(coordinator: fixture.coordinator, tabManager: fixture.tabManager, tabId: tab.id, driver: driver)
    }

    // The read a move started, once it has run.
    private func pageRead(_ page: KeyedPage, after earlier: Int = 0) async throws -> SentRead {
        try await waitUntil {
            page.driver.reads.count > earlier && !page.coordinator.tabExecution.isExecuting(page.tabId)
        }
        return page.driver.reads[earlier]
    }

    private func query(_ page: KeyedPage) -> String? {
        page.tabManager.tabs.first { $0.id == page.tabId }?.content.query
    }

    @Test("Next page in key order seeks past the last row on screen, the key bound and asked about once")
    func nextPageSeeksPastTheLastKey() async throws {
        let page = makeKeyedPage(page: 3)
        page.coordinator.goToNextPage()
        let read = try await pageRead(page)
        #expect(read == SentRead(
            sql: "SELECT * FROM `users` WHERE `id` > ? ORDER BY `id` ASC LIMIT 10 OFFSET 0", parameters: ["30"]
        ))
        let state = pagination(page.tabManager, page.tabId)
        #expect(state?.currentPage == 4)
        #expect(state?.currentOffset == 30)
        #expect(state?.seek == nil)
        #expect(query(page) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 30")
        #expect(page.driver.keyQuestions == 1)
    }

    @Test("The driver is asked about the key before every keyed read, and a failed ask keeps the offset")
    func keyAnswerIsAskedEachRead() async throws {
        let page = makeKeyedPage(page: 3)
        let tab = try #require(page.tabManager.tabs.first { $0.id == page.tabId })
        let scope = try #require(page.coordinator.scope(for: tab))
        let statement = KeyedPageStatement(
            sql: "SELECT 1", keyValues: [TypedParameterValue(text: "1", kind: .integer)], readsBackward: false
        )
        #expect(await page.coordinator.confirmedKeyedPage(statement, table: "users", scope: scope) == statement)
        #expect(await page.coordinator.confirmedKeyedPage(statement, table: "users", scope: scope) == statement)
        #expect(page.driver.keyQuestions == 2)

        let elsewhere = DatabaseScope(connectionId: UUID(), database: "nowhere", schema: nil)
        #expect(await page.coordinator.confirmedKeyedPage(statement, table: "users", scope: elsewhere) == nil)
    }

    @Test("A user's sort on the key seeks too")
    func userSortOnTheKeySeeks() async throws {
        let page = makeKeyedPage(page: 3, sortSource: .user)
        page.coordinator.goToNextPage()
        #expect(try await pageRead(page).sql.contains("`id` > ?"))
    }

    @Test("Previous page reads backward from the first row")
    func previousPageReadsBackward() async throws {
        let page = makeKeyedPage(page: 4)
        page.coordinator.goToPreviousPage()
        #expect(try await pageRead(page) == SentRead(
            sql: "SELECT * FROM `users` WHERE `id` < ? ORDER BY `id` DESC LIMIT 10 OFFSET 0", parameters: ["31"]
        ))
        #expect(pagination(page.tabManager, page.tabId)?.currentPage == 3)
        #expect(query(page) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 20")
    }

    @Test("Back to page 1 reads from the start")
    func previousToFirstPageReadsFromTheStart() async throws {
        let page = makeKeyedPage(page: 2)
        page.coordinator.goToPreviousPage()
        #expect(try await pageRead(page) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 0", parameters: nil
        ))
    }

    @Test("Last page reads the tail backward instead of skipping every row before it")
    func lastPageReadsTheTail() async throws {
        let page = makeKeyedPage(page: 2)
        page.coordinator.goToLastPage()
        #expect(try await pageRead(page) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` DESC LIMIT 10 OFFSET 0", parameters: nil
        ))
        #expect(pagination(page.tabManager, page.tabId)?.currentPage == 10)
        #expect(query(page) == "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 90")
    }

    @Test("A jump to a page in the middle, and a table with no key, keep the offset")
    func jumpsAndUnkeyedTablesKeepTheOffset() async throws {
        let page = makeKeyedPage(page: 2)
        page.coordinator.goToPage(6)
        #expect(try await pageRead(page) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 50", parameters: nil
        ))

        let unkeyed = makeKeyedPage(page: 3, keyed: false)
        unkeyed.coordinator.goToNextPage()
        #expect(try await pageRead(unkeyed) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 30", parameters: nil
        ))
    }

    // Redshift accepts two rows with one primary key, and a seek past one of them would skip the other.
    @Test("An engine that does not enforce its keys keeps the offset")
    func unenforcedKeysKeepTheOffset() async throws {
        let page = makeKeyedPage(page: 3, type: .redshift)
        page.coordinator.goToNextPage()
        let read = try await pageRead(page)
        #expect(read.parameters == nil)
        #expect(read.sql.hasSuffix("LIMIT 10 OFFSET 30"))
        #expect(pagination(page.tabManager, page.tabId)?.currentPage == 4)
    }

    // A PostgreSQL inheritance parent reads its children's rows too, and its key covers only its own.
    @Test("A table whose key can repeat across what it reads keeps the offset")
    func repeatingKeyKeepsTheOffset() async throws {
        let page = makeKeyedPage(page: 3, keyNamesOneRow: false)
        page.coordinator.goToNextPage()
        #expect(try await pageRead(page) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 30", parameters: nil
        ))
        #expect(page.driver.keyQuestions == 1)
    }

    // SQLite takes NULL in a primary key that is not its rowid, `INTEGER PRIMARY KEY DESC` included, and a seek passes
    // over every NULL key.
    @Test("A key the catalog says can hold NULL keeps the offset, a lone INTEGER key too")
    func nullableKeyKeepsTheOffset() async throws {
        let page = makeKeyedPage(page: 3, type: .sqlite, keyIsNullable: true)
        page.coordinator.goToNextPage()
        let read = try await pageRead(page)
        #expect(read.parameters == nil)
        #expect(read.sql.hasSuffix("LIMIT 10 OFFSET 30"))

        var rows = TableRows.from(queryRows: [], columns: ["id"], columnTypes: [.integer(rawType: "INTEGER")])
        rows.columnNullable = ["id": true]
        #expect(!MainContentCoordinator.keyHoldsNoNull(["id"], in: rows))
        rows.columnDeclaredTypes = ["id": "integer"]
        #expect(!MainContentCoordinator.keyHoldsNoNull(["id"], in: rows))
        rows.columnNullable = ["id": false]
        #expect(MainContentCoordinator.keyHoldsNoNull(["id"], in: rows))
        #expect(!MainContentCoordinator.keyHoldsNoNull(["id", "name"], in: rows))
    }

    // `é` as one scalar and as `e` with a combining accent: one name to Swift, two columns to PostgreSQL and SQLite.
    @Test("A table with two columns spelled alike in other scalars keeps the offset")
    func normalizationSpellingsKeepTheOffset() async throws {
        let page = makeKeyedPage(page: 3, type: .sqlite, columns: ["cafe\u{301}", "name"])
        page.tabManager.mutate(tabId: page.tabId) { $0.tableContext.primaryKeyColumns = ["caf\u{E9}"] }
        page.coordinator.goToNextPage()
        #expect(try await pageRead(page).parameters == nil)
        #expect(MainContentCoordinator.namesKeepTheirSpelling(["caf\u{E9}", "name"]))
        #expect(!MainContentCoordinator.namesKeepTheirSpelling(["caf\u{E9}", "cafe\u{301}"]))
    }

    // Next held down repeats before the page it asked for lands, and a stopped or failed load leaves the page before.
    @Test("Rows on screen from another page's statement keep the offset")
    func rowsOfAnotherPageKeepTheOffset() async throws {
        let page = makeKeyedPage(page: 3, pageHasLanded: false)
        page.coordinator.goToNextPage()
        let read = try await pageRead(page)
        #expect(read.parameters == nil)
        #expect(read.sql.hasSuffix("LIMIT 10 OFFSET 30"))
    }

    @Test("A masked key keeps the offset, since its cells hold the mask's text")
    func maskedKeyKeepsTheOffset() async throws {
        let page = makeKeyedPage(page: 3, masksKey: true)
        page.coordinator.goToNextPage()
        #expect(try await pageRead(page).parameters == nil)
    }

    @Test("Reading the page again, after a refresh or a return to a stale tab, reads it at its offset")
    func rereadReadsAtTheOffset() async throws {
        let page = makeKeyedPage(page: 4)
        page.coordinator.goToNextPage()
        #expect(try await pageRead(page).parameters == ["40"])
        page.coordinator.reloadTableTab(page.tabId)
        #expect(try await pageRead(page, after: 1) == SentRead(
            sql: "SELECT * FROM `users` ORDER BY `id` ASC LIMIT 10 OFFSET 40", parameters: nil
        ))
    }

    // The edge row's key can be a token or a session id; it goes to the driver as a value and nowhere else.
    @Test("The edge row's key reaches neither the saved tab nor query history")
    func edgeKeyIsNeverStored() async throws {
        let page = makeKeyedPage(
            page: 3, idType: .text(rawType: "VARCHAR(64)"), idText: { "tok_secret_\(1_000 + $0)" }
        )
        page.coordinator.goToNextPage()
        let read = try await pageRead(page)
        #expect(read.parameters == ["tok_secret_1030"])

        let tab = try #require(page.tabManager.tabs.first { $0.id == page.tabId })
        let saved = tab.toPersistedTab()
        #expect(!saved.query.contains("tok_secret"))
        #expect(saved.restoredPage == 4)

        let history = AppServices.live.queryHistoryManager
        let connectionId = page.coordinator.connection.id
        try await waitUntil { await history.count(scope: .connection(connectionId)) > 0 }
        let entries = await history.fetch(QueryHistoryFilter(scope: .connection(connectionId)), after: nil, limit: 10)
        #expect(!entries.entries.isEmpty)
        #expect(entries.entries.allSatisfy { !$0.query.contains("tok_secret") })
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

@MainActor
private struct KeyedPage {
    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    let tabId: UUID
    let driver: PageRecordingDriver
}

private struct SentRead: Equatable {
    let sql: String
    let parameters: [String?]?
}

/// Records each SELECT a page sends and answers it with a page of rows; asked whether a table's key names one row,
/// it answers what the case set.
private final class PageRecordingDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }
    private let answersKeyNamesOneRow: Bool

    private let lock = NSLock()
    private var recorded: [SentRead] = []
    private var asked = 0

    init(connection: DatabaseConnection, keyNamesOneRow: Bool) {
        self.connection = connection
        self.answersKeyNamesOneRow = keyNamesOneRow
    }

    var reads: [SentRead] {
        lock.withLock { recorded }
    }

    var keyQuestions: Int {
        lock.withLock { asked }
    }

    func primaryKeyNamesOneRow(inTable table: String, schema: String?) async throws -> Bool {
        lock.withLock { asked += 1 }
        return answersKeyNamesOneRow
    }

    private func record(_ query: String, parameters: [Any?]?) -> QueryResult {
        guard query.uppercased().hasPrefix("SELECT") else {
            return QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
        }
        let bound = parameters.map { values in values.map { ($0 as? TypedParameterValue)?.text ?? $0 as? String } }
        lock.withLock { recorded.append(SentRead(sql: query, parameters: bound)) }
        return QueryResult(
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)],
            rows: (1...10).map { [PluginCellValue.text(String($0)), .text("user \($0)")] },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    func execute(query: String) async throws -> QueryResult { record(query, parameters: nil) }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        record(query, parameters: parameters)
    }
    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        record(query, parameters: parameters)
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func ping() async throws {}
    func cancelQuery() throws {}
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func fetchTables(schema: String?) async throws -> [TableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns(schema: String?) async throws -> [CatalogName: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] { [] }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(tableName: String, schema: String?) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil, avgRowLength: nil,
            rowCount: nil, comment: nil, engine: nil, collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}
