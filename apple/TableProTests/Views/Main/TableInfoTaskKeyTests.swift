//
//  TableInfoTaskKeyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// The Table Info load runs again only when this key changes, and it waits for the tab's rows. A key
/// that did not move when the rows arrived left a table tab that had just opened with no numbers
/// until the inspector left the screen and came back.
@MainActor
struct TableInfoTaskKeyTests {
    private let table = TableTabIdentity(table: "orders", database: "shop", schema: nil)

    private func tableTab(executedAt: Date?) -> QueryTab {
        var tab = QueryTab(title: "orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders")
        tab.execution.lastExecutedAt = executedAt
        return tab
    }

    private func key(_ tab: QueryTab, onScreen: Bool = true) -> MainContentView.TableInfoTaskKey {
        MainContentView.TableInfoTaskKey(tab: tab, table: table, isInspectorOnScreen: onScreen)
    }

    @Test("The load runs again once a table tab's rows arrive")
    func rowsArrivingMoveTheKey() {
        var tab = tableTab(executedAt: nil)
        let opened = key(tab)

        tab.execution.lastExecutedAt = Date()

        #expect(key(tab) != opened)
    }

    /// A page, a sort or a filter runs the query again and changes none of the numbers. A read per
    /// run would count up to 100,001 rows on SQLite and run `collStats` on MongoDB on every page.
    @Test("A page, a sort or a filter does not read the statistics again")
    func rerunKeepsTheKey() {
        var tab = tableTab(executedAt: Date(timeIntervalSince1970: 1))
        let first = key(tab)

        tab.execution.lastExecutedAt = Date(timeIntervalSince1970: 2)

        #expect(key(tab) == first)
    }

    @Test("The inspector coming on screen runs the load again")
    func comingOnScreenMovesTheKey() {
        let tab = tableTab(executedAt: Date())

        #expect(key(tab, onScreen: true) != key(tab, onScreen: false))
    }

    @Test("A redraw that moves nothing the load reads keeps the key, so nothing reloads")
    func unrelatedChangeKeepsTheKey() {
        var tab = tableTab(executedAt: Date())
        let before = key(tab)

        tab.selectedRowIndices = [3]
        tab.schemaVersion += 1

        #expect(key(tab) == before)
    }
}
