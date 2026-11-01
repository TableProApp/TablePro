//
//  MaskingGridTests.swift
//  TableProTests
//
//  The grid, Copy and Copy As, the row inspector, charts and the assistant's result summary all read the tab's
//  TableRows, so a masked value never written there cannot reach any of them.
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private let rawEmails: Set<String> = ["jane@example.com", "john@example.com", "ann@example.com", "bob@example.com"]

private func leaks(_ rows: TableRows) -> Bool {
    rows.rows.contains { row in row.values.contains { $0.asText.map(rawEmails.contains) == true } }
}

struct MaskingTableRowsTests {
    private let masks = MaskingPolicy(rules: [MaskingRule(pattern: "*.email")])
        .columnMasks(table: "users", columns: ["id", "email"], typeNames: [nil, nil])

    @Test("Every write of fetched rows masks: the first page, a reload, a page appended and a value loaded later")
    func everyFetchedWriteIsMasked() {
        var rows = TableRows.from(
            queryRows: [[.text("1"), .text("jane@example.com")], [.text("2"), .null]],
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)],
            unloadedCells: [1: [1: 4_000]],
            masks: masks
        )
        #expect(!leaks(rows))

        rows.fillUnloaded([.existing(1): [1: .text("john@example.com")]])
        #expect(!leaks(rows))
        #expect(rows.value(at: 1, column: 1) == .text("••••"))

        rows.appendPage([[.text("3"), .text("ann@example.com")]], startingAt: 2)
        #expect(!leaks(rows))

        rows.replace(rows: [[.text("4"), .text("bob@example.com")]])
        #expect(!leaks(rows))
        #expect(rows.value(at: 0, column: 0) == .text("4"))
    }

    @Test("A rule saved while rows are loaded masks them in place and keeps an existing mask")
    func addedMasksApplyToLoadedRows() {
        var rows = TableRows.from(
            queryRows: [[.text("1"), .text("jane@example.com")]],
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        #expect(rows.addMasks(masks) == .fullReplace)
        #expect(!leaks(rows))
        #expect(rows.masks.isMasked(1))

        let restyled = ColumnMasks(styles: [1: .hash])
        #expect(rows.addMasks(restyled) == .none)
        #expect(rows.value(at: 0, column: 1) == .text("••••"))
    }

    @Test("A masked cell takes no edit, so a mask is never staged as a new value")
    func maskedCellRefusesEdits() {
        var rows = TableRows.from(
            queryRows: [[.text("1"), .text("jane@example.com")]],
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)],
            masks: masks
        )
        #expect(rows.edit(row: 0, column: 1, value: .text("new@example.com")) == .none)
        #expect(rows.value(at: 0, column: 1) == .text("••••"))
        #expect(rows.edit(row: 0, column: 0, value: .text("9")) != .none)
        #expect(rows.maskedColumnNames == ["email"])
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct MaskingGridTests {
        private let fixture: CoordinatorFixture = {
            var connection = TestFixtures.makeConnection(database: "shop")
            connection.maskingRules = [MaskingRule(pattern: "*.email", style: .email)]
            return CoordinatorFixture(connection: connection)
        }()

        private func loadUsers() throws -> QueryTab {
            let tab = fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
            fixture.coordinator.applyPhase1Result(
                tabId: tab.id,
                columns: ["id", "email"],
                columnTypes: [.integer(rawType: "int"), .text(rawType: "varchar")],
                rows: [[.text("1"), .text("jane@example.com")], [.text("2"), .text("john@example.com")]],
                executionTime: 0,
                rowsAffected: 0,
                statusMessage: nil,
                tableName: "users",
                isEditable: true,
                metadata: nil,
                hasSchema: false,
                read: TableFreshness.Read(startedAt: .now, includesDefinition: false),
                sql: "SELECT * FROM users",
                connection: fixture.connection
            )
            return try #require(fixture.tabManager.tabs.first { $0.id == tab.id })
        }

        @Test("A fetched result lands in the grid masked")
        func fetchedRowsAreMasked() throws {
            let tab = try loadUsers()
            let rows = fixture.coordinator.tabSessionRegistry.tableRows(for: tab.id)
            #expect(!leaks(rows))
            #expect(rows.value(at: 0, column: 1) == .text("j•••@example.com"))
            #expect(fixture.coordinator.gridModel(forTab: tab.id).rows.masks.isMasked(1))
        }

        @Test("Copy and Copy as JSON copy the mask")
        func copiesAreMasked() throws {
            let clipboard = try #require(RecordingClipboard.current)
            _ = try loadUsers()

            fixture.coordinator.copyRowsAsJson([.existing(0), .existing(1)])

            let copied = try #require(clipboard.text)
            #expect(!copied.contains("jane@example.com"))
            #expect(copied.contains("j•••@example.com"))
        }

        @Test("A grid holding masked values is read-only and says why")
        func maskedGridIsReadOnly() throws {
            _ = try loadUsers()
            #expect(fixture.coordinator.activeResultEditRefusal == .masked)
            #expect(!fixture.coordinator.canEditActiveResult)
        }

        @Test("Reveal is refused without authentication and shows raw values for that tab once granted")
        func revealNeedsAuthentication() async throws {
            let tab = try loadUsers()
            // Unselected, so a granted reveal records the choice without starting a query on a tab with no driver.
            fixture.tabManager.selectedTabId = nil

            await fixture.coordinator.revealMaskedValues(tabId: tab.id, authenticator: StubAuthenticating(answer: false))
            #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.revealsMaskedValues == false)

            await fixture.coordinator.revealMaskedValues(tabId: tab.id, authenticator: StubAuthenticating(answer: true))
            #expect(fixture.tabManager.tabs.first { $0.id == tab.id }?.revealsMaskedValues == true)
            let masks = fixture.coordinator.columnMasks(
                forTabId: tab.id, table: "users", columns: ["email"], columnTypes: [.text(rawType: nil)]
            )
            #expect(masks.isEmpty)
        }

        @Test("Another tab stays masked after one tab reveals")
        func revealIsPerTab() async throws {
            let revealed = try loadUsers()
            let other = fixture.addTab(QueryTab(title: "Q", query: "SELECT email FROM users", tabType: .query), select: false)
            fixture.tabManager.selectedTabId = nil

            await fixture.coordinator.revealMaskedValues(tabId: revealed.id, authenticator: StubAuthenticating(answer: true))

            let masks = fixture.coordinator.columnMasks(
                forTabId: other.id, table: nil, columns: ["email"], columnTypes: [.text(rawType: nil)]
            )
            #expect(masks.isMasked(0))
        }
    }
}
