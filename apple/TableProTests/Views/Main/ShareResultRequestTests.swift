//
//  ShareResultRequestTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    @MainActor
    struct ShareResultRequestTests {
        private let fixture: CoordinatorFixture = {
            var connection = TestFixtures.makeConnection(database: "shop")
            connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email)]
            return CoordinatorFixture(connection: connection)
        }()

        private static let emails = ["jane@example.com", "john@example.com", "ann@example.com"]

        private static let tracedOrigins = ["id", "email", "note"].map { PluginColumnOrigin(schema: "shop", table: "users", column: $0) }

        private func load(
            _ tab: QueryTab,
            origins: [PluginColumnOrigin?]? = tracedOrigins,
            isTruncated: Bool = false,
            into fixture: CoordinatorFixture? = nil
        ) throws -> QueryTab {
            let fixture = fixture ?? self.fixture
            let added = fixture.tabManager.tabs.contains { $0.id == tab.id } ? tab : fixture.addTab(tab)
            fixture.coordinator.applyPhase1Result(
                tabId: added.id,
                columns: ["id", "email", "note"],
                columnTypes: [.integer(rawType: "int"), .text(rawType: "varchar"), .text(rawType: "varchar")],
                rows: Self.emails.enumerated().map { index, email in
                    [.text(String(index + 1)), .text(email), .text("note \(index)")]
                },
                executionTime: 0,
                rowsAffected: 0,
                statusMessage: nil,
                tableName: tab.tabType == .table ? tab.tableContext.tableName : nil,
                isEditable: false,
                metadata: nil,
                hasSchema: false,
                read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
                sql: tab.content.query,
                connection: fixture.connection,
                isTruncated: isTruncated,
                columnOrigins: origins
            )
            return try #require(fixture.tabManager.tabs.first { $0.id == added.id })
        }

        // MARK: - Reading past the rows held

        private static func answer(origins: [PluginColumnOrigin?]?) -> @Sendable (String) -> PluginQueryResult {
            { _ in
                var result = PluginQueryResult(
                    columns: ["id", "email", "note"],
                    columnTypeNames: ["int8", "text", "text"],
                    rows: (1...5).map { [.text(String($0)), .text("user\($0)@example.com"), .text("note \($0)")] },
                    rowsAffected: 0,
                    executionTime: 0
                )
                result.columnOrigins = origins
                return result
            }
        }

        // A coordinator whose connection has a live session answering every statement from `driver`.
        private static func drivenFixture(_ driver: AnsweringPluginDriver) -> CoordinatorFixture {
            var connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
            connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email)]
            _ = AnsweringPluginDriver.install(driver, connection: connection)
            let fixture = CoordinatorFixture(connection: connection)
            fixture.coordinator.executionGate = AlwaysAllowGate()
            return fixture
        }

        private static func source(of fixture: CoordinatorFixture, maxRows: Int = 1_000) async throws -> ShareResultSource? {
            let request = try #require(fixture.coordinator.activeResultShareRequest())
            let load = try #require(request.loadResult)
            return await load(maxRows)
        }

        @Test("A cut read is read again up to max_rows in its own statement, masked by the rules")
        func cutReadIsReadAgainMasked() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: Self.tracedOrigins))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            _ = try load(QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query), isTruncated: true, into: fixture)

            let shared = try #require(try await Self.source(of: fixture))

            #expect(driver.sent.map(\.query) == ["SELECT id, email, note FROM users"])
            #expect(driver.sent.first?.rowCap == 1_000)
            #expect(shared.rows.count == 5)
            #expect(shared.rows.map { $0[1] } == Array(repeating: .text("u•••@example.com"), count: 5))
            #expect(shared.rows.first?[2] == .text("note 1"))
            #expect(shared.masks == ColumnMasks(styles: [1: .email]))
        }

        @Test("A cut read nothing traced is read again with every column masked whole")
        func untracedReadIsMaskedWhole() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: nil))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            _ = try load(
                QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query),
                origins: nil, isTruncated: true, into: fixture
            )

            let shared = try #require(try await Self.source(of: fixture))

            #expect(driver.sent.count == 1)
            #expect(shared.untracedColumns == [0, 1, 2])
            #expect(shared.masks == ColumnMasks(styles: [0: .full, 1: .full, 2: .full]))
            #expect(shared.rows.allSatisfy { row in row == Array(repeating: PluginCellValue.text("••••"), count: 3) })
        }

        @Test("A cut write that returned rows never runs again: the rows held go, marked as cut")
        func cutWriteIsNotRunAgain() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: Self.tracedOrigins))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            let sql = "UPDATE users SET seen = true RETURNING id, email, note"
            _ = try load(QueryTab(title: "Q", query: sql, tabType: .query), isTruncated: true, into: fixture)

            let shared = try #require(try await Self.source(of: fixture))

            #expect(driver.sent.isEmpty)
            #expect(shared.rows.count == 3)
            #expect(shared.totalRowCount == nil)
            #expect(shared.sql == sql)
        }

        @Test("A cut result read in another database is not read again in the tab's")
        func resultReadElsewhereIsNotReadAgain() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: Self.tracedOrigins))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            let tab = try load(
                QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query), isTruncated: true, into: fixture
            )
            tab.display.activeResultSet?.origin = ResultOrigin(tableName: "users", databaseName: "archive")

            let shared = try #require(try await Self.source(of: fixture))

            #expect(driver.sent.isEmpty)
            #expect(shared.rows.count == 3)
            #expect(shared.totalRowCount == nil)
        }

        @Test("Once the tab shows another statement's result, the sheet's loader reads nothing and finds no rows")
        func replacedResultReadsNothing() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: Self.tracedOrigins))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            let tab = try load(
                QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query), isTruncated: true, into: fixture
            )
            let request = try #require(fixture.coordinator.activeResultShareRequest())
            let loader = try #require(request.loadResult)
            var other = tab
            other.content.query = "SELECT id, email, note FROM archived_users"
            _ = try load(other, isTruncated: true, into: fixture)

            #expect(await loader(1_000) == nil)
            #expect(driver.sent.isEmpty)
        }

        @Test("A refresh of the same table view, as Auto Refresh installs, still shares; another database does not")
        func refreshedTableViewStillShares() async throws {
            fixture.coordinator.queryBuilder = TableQueryBuilder(
                databaseType: .mysql, pagination: .offset, dialectQuote: SQLEscaping.quoteIdentifier
            )
            let tab = try load(
                QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"), origins: nil
            )
            let request = try #require(fixture.coordinator.activeResultShareRequest())
            let loader = try #require(request.loadResult)
            let opened = fixture.tabManager.tabs.first { $0.id == tab.id }?.display.activeResultSet?.id

            _ = try load(tab, origins: nil)
            #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.display.activeResultSet?.id != opened)
            #expect(await loader(1_000)?.rows.count == 3)

            fixture.tabManager.mutate(tabId: tab.id) { $0.tableContext.databaseName = "archive" }
            #expect(await loader(1_000) == nil)
        }

        @Test("A table tab's view past the page is read with the page's limit off, masked by the rules")
        func tableViewReadIsMasked() async throws {
            let driver = AnsweringPluginDriver(answer: Self.answer(origins: nil))
            let fixture = Self.drivenFixture(driver)
            defer { DatabaseManager.shared.removeSession(for: fixture.connection.id) }
            fixture.coordinator.queryBuilder = TableQueryBuilder(
                databaseType: .postgresql,
                dialect: SQLDialectDescriptor(
                    identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
                    regexSyntax: .regexp, booleanLiteralStyle: .numeric,
                    likeEscapeStyle: .implicit, paginationStyle: .limit
                ),
                pagination: .offset,
                dialectQuote: SQLEscaping.quoteIdentifier
            )
            let tab = try load(
                QueryTab(title: "users", query: "SELECT * FROM \"users\" LIMIT 3", tabType: .table, tableName: "users"),
                origins: nil, into: fixture
            )
            fixture.tabManager.mutate(tabId: tab.id) {
                $0.pagination.totalRowCount = 5
                $0.pagination.isApproximateRowCount = false
            }

            let shared = try #require(try await Self.source(of: fixture))

            #expect(driver.sent.count == 1)
            #expect(driver.sent.first?.query.contains("users") == true)
            #expect(driver.sent.first?.rowCap == 1_000)
            #expect(shared.rows.count == 5)
            #expect(shared.rows.map { $0[1] } == Array(repeating: .text("u•••@example.com"), count: 5))
            #expect(shared.masks == ColumnMasks(styles: [1: .email]))
            #expect(shared.totalRowCount == 5)
        }

        @Test("A read for a sheet that closed stops and gives nothing")
        func cancelledReadGivesNothing() async throws {
            _ = try load(QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query))
            let request = try #require(fixture.coordinator.activeResultShareRequest())
            let load = try #require(request.loadResult)

            let read = Task { await load(1_000) }
            read.cancel()
            #expect(await read.value == nil)
        }

        @Test("Only a change to the connection's masking rules makes the share read its rows again")
        func onlyRuleChangesSignalTheSheet() async throws {
            let events = AppEvents()
            let suite = try EphemeralDefaults()
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("share-rules-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let storage = ConnectionStorage(
                fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain(), appEvents: events
            )
            var connection = fixture.connection
            _ = storage.addConnection(connection)
            let services = AppServices.live.replacing(databaseManager: DatabaseManager(connectionStorage: storage), appEvents: events)
            let ruled = CoordinatorFixture(connection: connection, services: services)
            _ = try load(QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query), into: ruled)
            let changes = try #require(ruled.coordinator.activeResultShareRequest()?.sourceChanges)
            let signals = Signals()
            let delivered = Signals()
            let observation = changes.sink { signals.count += 1 }
            let probe = events.connectionUpdated.receive(on: RunLoop.main).sink { _ in delivered.count += 1 }
            defer {
                observation.cancel()
                probe.cancel()
            }

            connection.name = "Renamed"
            storage.updateConnection(connection)
            events.connectionUpdated.send(connection.id)
            events.connectionUpdated.send(nil)
            try await waitUntil { delivered.count == 2 }
            #expect(signals.count == 0)

            connection.maskingRules += [MaskingRule(pattern: "*.note", style: .full)]
            storage.updateConnection(connection)
            events.connectionUpdated.send(connection.id)
            try await waitUntil { signals.count == 1 }
            #expect(delivered.count == 3)
        }

        @MainActor
        private final class Signals {
            var count = 0
        }

        private func source(maxRows: Int = 1_000) async throws -> ShareResultSource {
            let request = try #require(fixture.coordinator.activeResultShareRequest())
            let load = try #require(request.loadResult)
            return try #require(await load(maxRows))
        }

        private func setPagination(_ tabId: UUID, _ change: (inout PaginationState) -> Void) {
            fixture.tabManager.mutate(tabId: tabId) { change(&$0.pagination) }
        }

        @Test("Share Result reads the grid as shown: masked after Reveal, hidden columns out, pending deletes skipped")
        func readsTheGridAsShown() async throws {
            var tab = QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query)
            tab.revealsMaskedValues = true
            tab.columnLayout.hiddenColumns = ["note"]
            let loaded = try load(tab)
            let rows = fixture.coordinator.tabSessionRegistry.tableRows(for: loaded.id)
            #expect(rows.rows.contains { $0.values.contains(.text("jane@example.com")) })

            fixture.changeManager.recordRowDeletion(rowID: rows.rows[1].id, originalRow: Array(rows.rows[1].values))
            let shared = try await source()

            #expect(shared.columns == ["id", "email"])
            #expect(shared.rows.map { $0.first } == [.text("1"), .text("3")])
            #expect(!shared.rows.contains { row in row.contains { Self.emails.contains($0.asText ?? "") } })
            #expect(shared.sql == "SELECT id, email, note FROM users")
        }

        @Test("The source says which shared columns the rules masked, at their place after hidden columns")
        func sourceCarriesRuleMasks() async throws {
            var tab = QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query)
            tab.columnLayout.hiddenColumns = ["id"]
            _ = try load(tab)
            let shared = try await source()

            #expect(shared.columns == ["email", "note"])
            #expect(shared.masks == ColumnMasks(styles: [0: .email]))
            #expect(shared.rows.first?.first == .text("j•••@example.com"))
        }

        @Test("A column nothing traced is masked whole and marked untraced, at its place after hidden columns")
        func untracedColumnsAreMarked() async throws {
            var tab = QueryTab(title: "Q", query: "SELECT id, email, note FROM users", tabType: .query)
            tab.columnLayout.hiddenColumns = ["id"]
            _ = try load(tab, origins: [Self.tracedOrigins[0], Self.tracedOrigins[1], nil])
            let shared = try await source()

            #expect(shared.columns == ["email", "note"])
            #expect(shared.untracedColumns == [1])
            #expect(shared.masks == ColumnMasks(styles: [0: .email, 1: .full]))
            #expect(shared.rows.first?.last == .text("••••"))
        }

        @Test("A result cut short sends its exact count")
        func exactCountIsTheTotal() async throws {
            let tab = try load(QueryTab(title: "Q", query: "SELECT * FROM users", tabType: .query))
            setPagination(tab.id) {
                $0.hasMoreRows = true
                $0.totalRowCount = 500
                $0.isApproximateRowCount = false
            }
            #expect(try await source().totalRowCount == 500)
        }

        @Test("An estimate above the rows held stands in for the total")
        func estimateAboveTheRowsIsTheTotal() async throws {
            let tab = try load(QueryTab(title: "Q", query: "SELECT * FROM users", tabType: .query))
            setPagination(tab.id) {
                $0.hasMoreRows = true
                $0.totalRowCount = 10_000
                $0.isApproximateRowCount = true
            }
            #expect(try await source().totalRowCount == 10_000)
        }

        @Test("More rows than max_rows with no count read only max_rows positions and leave the total unknown")
        func cutWithoutACountIsUnknown() async throws {
            let tab = try load(QueryTab(title: "Q", query: "SELECT * FROM users", tabType: .query))
            setPagination(tab.id) {
                $0.totalRowCount = nil
                $0.hasMoreRows = false
            }
            let shared = try await source(maxRows: 2)
            #expect(shared.rows.count == 2)
            #expect(shared.totalRowCount == nil)
        }

        @Test("A table tab shares its view's SQL without the page's LIMIT and OFFSET")
        func tableTabSharesItsViewWithoutWindow() throws {
            fixture.coordinator.queryBuilder = TableQueryBuilder(
                databaseType: .mysql,
                dialect: SQLDialectDescriptor(
                    identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
                    regexSyntax: .regexp, booleanLiteralStyle: .numeric,
                    likeEscapeStyle: .implicit, paginationStyle: .limit
                ),
                pagination: .offset,
                dialectQuote: SQLEscaping.quoteIdentifier
            )
            var tab = QueryTab(title: "users", query: "SELECT * FROM `users` LIMIT 1000 OFFSET 3000", tabType: .table, tableName: "users")
            tab.pagination.currentOffset = 3_000
            fixture.addTab(tab)

            #expect(fixture.coordinator.shareSQL(of: tab) == "SELECT * FROM \"users\"")
        }

        @Test("A table view the host cannot write as SQL shares no SQL")
        func dialectlessTableSharesNoSQL() {
            fixture.coordinator.queryBuilder = TableQueryBuilder(
                databaseType: .mysql, pagination: .offset, dialectQuote: SQLEscaping.quoteIdentifier
            )
            let tab = QueryTab(title: "users", query: "", tabType: .table, tableName: "users")
            fixture.addTab(tab)
            #expect(fixture.coordinator.shareSQL(of: tab).isEmpty)
        }

        @Test("A whole result held in the grid is its own total")
        func wholeResultCountsItself() async throws {
            let tab = try load(QueryTab(title: "Q", query: "SELECT * FROM users", tabType: .query))
            setPagination(tab.id) {
                $0.totalRowCount = nil
                $0.hasMoreRows = false
            }
            let shared = try await source()
            #expect(shared.rows.count == 3)
            #expect(shared.totalRowCount == 3)
        }
    }
}

@MainActor
private extension AppServices {
    func replacing(databaseManager: DatabaseManager, appEvents: AppEvents) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
