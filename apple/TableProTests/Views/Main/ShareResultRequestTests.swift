//
//  ShareResultRequestTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
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

        private func load(_ tab: QueryTab) throws -> QueryTab {
            let added = fixture.addTab(tab)
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
                tableName: nil,
                isEditable: false,
                metadata: nil,
                hasSchema: false,
                read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
                sql: tab.content.query,
                connection: fixture.connection,
                columnOrigins: ["id", "email", "note"].map { PluginColumnOrigin(schema: "shop", table: "users", column: $0) }
            )
            return try #require(fixture.tabManager.tabs.first { $0.id == added.id })
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
