//
//  MaskingExternalReaderTests.swift
//  TableProTests
//
//  The assistant's result summary, the row inspector's assistant pane, Fix with AI and AppleScript read a tab's rows
//  and errors outside the bridge, so they take the bridge's masking rather than the grid's by-name match.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MaskingExternalOverlayTests {
    private let policy = MaskingPolicy(rules: [MaskingRule(pattern: "*.email", style: .email)])
    private let columns = ["contact", "email", "id"]
    private let types: [ColumnType] = [.text(rawType: nil), .text(rawType: nil), .integer(rawType: nil)]

    private func rows(origins: [PluginColumnOrigin?]?) -> TableRows {
        TableRows.from(
            queryRows: [[.text("jane@example.com"), .text("john@example.com"), .text("1")]],
            columns: columns,
            columnTypes: types,
            masks: policy.columnMasks(table: nil, columns: columns, columnTypes: types),
            columnOrigins: origins
        )
    }

    private func externallyMasked(_ rows: TableRows) -> TableRows {
        let external = policy.externalColumnMasks(
            table: nil, columns: rows.columns, typeNames: rows.columnTypes.map(\.rawType), origins: rows.columnOrigins
        )
        return rows.externallyMasked(by: rows.externalOverlay(external))
    }

    @Test("A traced alias the grid left readable is masked by the column it reads")
    func tracedAliasIsMasked() {
        let traced = rows(origins: [
            PluginColumnOrigin(schema: "shop", table: "users", column: "email"),
            PluginColumnOrigin(schema: "shop", table: "users", column: "email"),
            PluginColumnOrigin(schema: "shop", table: "users", column: "id"),
        ])

        #expect(traced.rows[0].values[0] == .text("jane@example.com"))
        #expect(externallyMasked(traced).rows[0].values == [
            .text("j•••@example.com"), .text("j•••@example.com"), .text("1"),
        ])
    }

    @Test("Without origins every column is masked whole, over what the grid already hid")
    func untracedRowsAreMaskedWhole() {
        #expect(externallyMasked(rows(origins: nil)).rows[0].values == [.text("••••"), .text("••••"), .text("••••")])
    }

    @Test("Origins reported for other columns are not used")
    func staleOriginsAreDropped() {
        var traced = rows(origins: [nil, nil, PluginColumnOrigin(schema: "shop", table: "users", column: "id")])
        #expect(traced.columnOrigins != nil)
        traced.columns = ["id", "contact", "email"]
        #expect(traced.columnOrigins == nil)
    }
}

extension GlobalStateSuites {
    @MainActor
    struct MaskingExternalReaderTests {
        private let fixture: CoordinatorFixture = {
            var connection = TestFixtures.makeConnection(database: "shop")
            connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email)]
            return CoordinatorFixture(connection: connection)
        }()

        private func load(
            _ tab: QueryTab,
            columns: [String],
            tableName: String?,
            origins: [PluginColumnOrigin?]? = nil
        ) throws -> QueryTab {
            let added = fixture.addTab(tab)
            fixture.coordinator.applyPhase1Result(
                tabId: added.id,
                columns: columns,
                columnTypes: columns.map { _ in ColumnType.text(rawType: "varchar") },
                rows: [columns.map { $0 == "id" ? PluginCellValue.text("1") : PluginCellValue.text("jane@example.com") }],
                executionTime: 0,
                rowsAffected: 0,
                statusMessage: nil,
                tableName: tableName,
                isEditable: false,
                metadata: nil,
                hasSchema: false,
                read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
                sql: tab.content.query,
                connection: fixture.connection,
                columnOrigins: origins
            )
            return try #require(fixture.tabManager.tabs.first { $0.id == added.id })
        }

        private static func leaks(_ rows: TableRows) -> Bool {
            rows.rows.contains { row in row.values.contains { $0.asText == "jane@example.com" } }
        }

        @Test("A query tab's alias reaches the assistant and scripts masked, though the grid shows it")
        func queryTabAliasIsMasked() throws {
            let tab = try load(
                QueryTab(title: "Q", query: "SELECT email AS contact, id FROM users", tabType: .query),
                columns: ["contact", "id"],
                tableName: nil
            )

            #expect(Self.leaks(fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id)))
            #expect(!Self.leaks(fixture.coordinator.externallyMaskedRows(forTab: tab.id)))
            #expect(fixture.coordinator.externalOverlay(forTab: tab.id).styles == [0: .full, 1: .full])
        }

        @Test("A traced query tab keeps the columns the rules leave alone")
        func tracedQueryTabKeepsUnruledColumns() throws {
            let tab = try load(
                QueryTab(title: "Q", query: "SELECT email AS contact, id FROM users", tabType: .query),
                columns: ["contact", "id"],
                tableName: nil,
                origins: [
                    PluginColumnOrigin(schema: "shop", table: "users", column: "email"),
                    PluginColumnOrigin(schema: "shop", table: "users", column: "id"),
                ]
            )

            let rows = fixture.coordinator.externallyMaskedRows(forTab: tab.id)
            #expect(rows.rows[0].values == [.text("j•••@example.com"), .text("1")])
        }

        @Test("A table tab is the app's own projection of that table, matched by name as the grid matches it")
        func tableTabMatchesByName() throws {
            let tab = try load(
                QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"),
                columns: ["id", "email"],
                tableName: "users"
            )

            #expect(fixture.coordinator.externalOverlay(forTab: tab.id).isEmpty)
            #expect(fixture.coordinator.externallyMaskedRows(forTab: tab.id).rows[0].values == [
                .text("1"), .text("j•••@example.com"),
            ])
        }

        @Test("Fix with AI gets the fixed sentence for an error on a connection with rules")
        func errorTextIsWithheld() {
            let error = #"invalid input syntax for type integer: "jane@example.com""#
            #expect(fixture.coordinator.externalErrorText(error) == ServerErrorText.withheldMessage)
            #expect(fixture.coordinator.externalErrorText(nil) == nil)
        }
    }
}
