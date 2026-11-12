//
//  QueryRunTabStripTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryRunTabStripTests {
    private static func results(_ labels: [String], activeIndex: Int = 0) -> ResultSetMenuModel {
        let entries = labels.enumerated().map { index, label in
            ResultSetMenuEntry(
                id: UUID(),
                label: label,
                isPinned: false,
                isActive: index == activeIndex,
                ordinal: index + 1,
                isComparable: true
            )
        }
        return ResultSetMenuModel(entries: entries, activeOrdinal: activeIndex + 1, total: entries.count)
    }

    private static func titles(_ strip: QueryRunTabStrip, _ results: ResultSetMenuModel) -> [String] {
        strip.segments.map { strip.title(of: $0, in: results) }
    }

    @Test("A result tab is named by its statement's number, a failed statement's by Error, and others keep their name")
    func resultTabsCarryTheStatementNumber() {
        let results = Self.results(["SELECT id, customer_id, status FROM orders", "SELECT status, COUNT(*)", "Error 3", "pinned"])
        let ids = results.entries.map(\.id)
        let log = QueryRunLog(startedAt: .now, entries: [
            QueryRunLogEntry(statement: "SELECT id, customer_id, status FROM orders", outcome: .returnedRows(6), resultSetId: ids[0]),
            QueryRunLogEntry(statement: "UPDATE orders SET total = 0", outcome: .affectedRows(2)),
            QueryRunLogEntry(statement: "SELECT status, COUNT(*)", outcome: .returnedRows(4), resultSetId: ids[1]),
            .failed("SELECT * FROM missing", message: "no such table", resultSetId: ids[2])
        ])
        let strip = QueryRunTabStrip(
            page: .result,
            results: results,
            listsEachResult: true,
            statementTitles: QueryRunTabStrip.statementTitles(in: log)
        )

        #expect(Self.titles(strip, results) == ["Message", "Summary", "Result 1", "Result 3", "Error 4", "pinned"])
        #expect(QueryRunTabStrip.toolTip(of: strip.segments[2], in: results) == "SELECT id, customer_id, status FROM orders")
        #expect(QueryRunTabStrip.statementTitles(in: nil).isEmpty)
    }

    @Test("Message and Summary lead the row, then a tab per result, even for one result")
    func messageSummaryThenEachResult() {
        let one = Self.results(["users"])
        let two = Self.results(["users", "orders"], activeIndex: 1)

        #expect(Self.titles(QueryRunTabStrip(page: .result, results: one, listsEachResult: true), one)
            == ["Message", "Summary", "users"])
        #expect(Self.titles(QueryRunTabStrip(page: .result, results: two, listsEachResult: true), two)
            == ["Message", "Summary", "users", "orders"])
    }

    @Test("The lit tab follows the page, and on a result page the active result")
    func litTabFollowsThePage() {
        let results = Self.results(["users", "orders", "Result 3"], activeIndex: 1)

        #expect(QueryRunTabStrip(page: .message, results: results, listsEachResult: true).selectedIndex == 0)
        #expect(QueryRunTabStrip(page: .summary, results: results, listsEachResult: true).selectedIndex == 1)
        #expect(QueryRunTabStrip(page: .result, results: results, listsEachResult: true).selectedIndex == 3)
        #expect(QueryRunTabStrip(page: .result, results: results, listsEachResult: false).selectedIndex == 2)
    }

    @Test("Folded, the results are one tab for the active result")
    func foldedRowShowsTheActiveResult() {
        let results = Self.results(["users", "orders", "invoices"], activeIndex: 2)
        let strip = QueryRunTabStrip(page: .message, results: results, listsEachResult: false)

        #expect(Self.titles(strip, results) == ["Message", "Summary", "invoices"])
    }

    @Test("A run with no results left still offers Message and Summary, with no result tab lit")
    func noResults() {
        let none = ResultSetMenuModel(entries: [], activeOrdinal: 0, total: 0)

        #expect(QueryRunTabStrip(page: .result, results: none, listsEachResult: true).segments == [.message, .summary])
        #expect(QueryRunTabStrip(page: .result, results: none, listsEachResult: true).selectedIndex == -1)
    }

    @Test("Up to six results get a tab each; past that the pull-down lists them")
    func sixResultsAtMost() {
        #expect(QueryRunTabStrip.canListEachResult(Self.results((1 ... 6).map { "r\($0)" })))
        #expect(!QueryRunTabStrip.canListEachResult(Self.results((1 ... 7).map { "r\($0)" })))
    }
}
