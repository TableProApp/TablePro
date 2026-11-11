//
//  QueryRunLogTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct QueryRunLogTests {
    private static let select = "SELECT id, name FROM users"
    private static let update = "UPDATE orders SET status = 'paid'"
    private static let failing = "SELECT * FROM nope"
    private static let later = "DELETE FROM sessions"
    private static let script = [select, update, failing, later]

    private func rowsResult(rowCount: Int, time: TimeInterval = 0.012) -> ResultSet {
        let rows = TableRows.from(
            queryRows: (0 ..< rowCount).map { [PluginCellValue.text("\($0)"), .text("name \($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        )
        let result = ResultSet(label: "users", tableRows: rows)
        result.executionTime = time
        return result
    }

    private func countResult(affected: Int, status: String? = nil) -> ResultSet {
        let result = ResultSet(label: "UPDATE orders")
        result.rowsAffected = affected
        result.statusMessage = status
        result.executionTime = 0.004
        return result
    }

    @Test("A run that failed lists what ran, then the failure, and leaves out what never ran")
    func failedRunListsEachStatement() {
        let rows = rowsResult(rowCount: 3)
        let count = countResult(affected: 12)
        let errorId = UUID()
        let finished = [
            QueryRunLogEntry(statement: Self.select, resultSet: rows),
            QueryRunLogEntry(statement: Self.update, resultSet: count),
        ]

        let log = QueryRunLog(
            startedAt: .now,
            entries: QueryRunLog.entries(
                statements: Self.script,
                finished: finished,
                ending: .failed(statement: Self.failing, message: "relation \"nope\" does not exist", resultSetId: errorId)
            )
        )

        #expect(log.entries.map(\.ordinal) == [1, 2, 3])
        #expect(log.entries.map(\.statement) == [Self.select, Self.update, Self.failing])
        #expect(log.entries.map(\.outcome) == [
            .returnedRows(3),
            .affectedRows(12),
            .failed(message: "relation \"nope\" does not exist"),
        ])
        #expect(log.entries.map(\.resultSetId) == [rows.id, count.id, errorId])
        #expect(log.entries.first?.executionTime == 0.012)
    }

    @Test("A stopped run names the statement it interrupted as cancelled and leaves out the rest")
    func stoppedRunNamesTheInterruptedStatement() {
        let finished = [
            QueryRunLogEntry(statement: Self.select, resultSet: rowsResult(rowCount: 2)),
            QueryRunLogEntry(statement: Self.update, resultSet: countResult(affected: 1)),
        ]

        let entries = QueryRunLog.entries(statements: Self.script, finished: finished, ending: .stopped)

        #expect(entries.map(\.statement) == [Self.select, Self.update, Self.failing])
        #expect(entries.last?.outcome == .cancelled)
        #expect(entries.last?.resultSetId == nil)
    }

    @Test("A run stopped after its last statement finished lists only what ran")
    func stopAfterTheLastStatementAddsNothing() {
        let finished = [QueryRunLogEntry(statement: Self.select, resultSet: rowsResult(rowCount: 1))]

        #expect(QueryRunLog.entries(statements: [Self.select], finished: finished, ending: .stopped) == finished)
        #expect(QueryRunLog.entries(statements: [Self.select], finished: finished, ending: .completed) == finished)
    }

    @Test("A failure outside any statement still gets an entry")
    func failureWithoutAStatement() {
        let entries = QueryRunLog.entries(
            statements: Self.script,
            finished: [],
            ending: .failed(statement: nil, message: "Connection reset", resultSetId: nil)
        )

        #expect(entries == [.failed("", message: "Connection reset")])
    }

    @Test("A statement whose results were not installed reads its counts from the driver's result")
    func driverResultEntry() {
        let returned = QueryResult(
            columns: ["id"], columnTypes: [.integer(rawType: nil)], rows: [[.text("1")], [.text("2")]],
            rowsAffected: 0, executionTime: 0.5, error: nil
        )
        let written = QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 7, executionTime: 0.1, error: nil)

        #expect(QueryRunLogEntry(statement: Self.select, result: returned).outcome == .returnedRows(2))
        #expect(QueryRunLogEntry(statement: Self.update, result: written).outcome == .affectedRows(7))
        #expect(QueryRunLogEntry(statement: Self.update, result: written).resultSetId == nil)
    }

    @Test("An empty row set is still rows returned, an error result is a failure and a plan is a plan")
    func outcomeFromResultSet() {
        let empty = rowsResult(rowCount: 0)
        let failed = ResultSet(label: "Error")
        failed.errorMessage = "boom"
        let plan = ResultSet(label: "Plan")
        plan.explainRawText = "Seq Scan on users"

        #expect(QueryRunLogEntry(statement: Self.select, resultSet: empty).outcome == .returnedRows(0))
        #expect(QueryRunLogEntry(statement: Self.failing, resultSet: failed).outcome == .failed(message: "boom"))
        #expect(QueryRunLogEntry(statement: "EXPLAIN SELECT 1", resultSet: plan).outcome == .plan)
    }

    // MARK: - Summary

    @Test("Each Summary row maps to the result its statement produced")
    func summaryRowsMapToResults() {
        let first = rowsResult(rowCount: 5)
        let second = countResult(affected: 2)
        let third = rowsResult(rowCount: 0)
        let log = QueryRunLog(startedAt: .now, entries: [
            QueryRunLogEntry(statement: Self.select, resultSet: first),
            QueryRunLogEntry(statement: Self.update, resultSet: second),
            QueryRunLogEntry(statement: Self.select, resultSet: third),
        ])

        #expect(log.resultSetId(ofEntry: 1) == first.id)
        #expect(log.resultSetId(ofEntry: 2) == second.id)
        #expect(log.resultSetId(ofEntry: 3) == third.id)
        #expect(log.resultSetId(ofEntry: 4) == nil)
        #expect(log.entries.map { QueryRunLog.rowCount(for: $0.outcome) } == [5, 2, 0])
        #expect(log.entries.map { QueryRunLog.statusText(for: $0.outcome) } == ["OK", "OK", "OK"])
    }

    @Test("Status and rows for a failure and a stop")
    func summaryForFailureAndStop() {
        #expect(QueryRunLog.statusText(for: .failed(message: "x")) == "Error")
        #expect(QueryRunLog.statusText(for: .cancelled) == "Cancelled")
        #expect(QueryRunLog.rowCount(for: .failed(message: "x")) == nil)
        #expect(QueryRunLog.rowCount(for: .cancelled) == nil)
        #expect(QueryRunLog.rowCount(for: .plan) == nil)
    }

    @Test("A re-read result keeps its Summary row pointing at it")
    func rereadKeepsTheMapping() {
        let outgoing = UUID()
        let incoming = UUID()
        let other = UUID()
        let log = QueryRunLog(startedAt: .now, entries: [
            QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(1), resultSetId: outgoing),
            QueryRunLogEntry(statement: Self.update, outcome: .affectedRows(1), resultSetId: other),
        ])

        let moved = log.replacingResult(outgoing, with: incoming)

        #expect(moved.entries.map(\.resultSetId) == [incoming, other])
        #expect(moved.startedAt == log.startedAt)
    }

    // MARK: - Message

    @Test("The message log gives each statement, its outcome, its output and its time, in order")
    func messageTextListsEveryStatement() {
        let rows = rowsResult(rowCount: 120)
        let count = countResult(affected: 12)
        count.serverOutput = PluginServerOutput(lines: ["NOTICE: trigger fired"], isTruncated: false)
        let log = QueryRunLog(
            startedAt: .now,
            entries: QueryRunLog.entries(
                statements: Self.script,
                finished: [
                    QueryRunLogEntry(statement: Self.select, resultSet: rows),
                    QueryRunLogEntry(statement: Self.update, resultSet: count),
                ],
                ending: .stopped
            ),
            notice: "The open transaction was not committed."
        )

        let lines = log.messageText.components(separatedBy: "\n")

        #expect(lines == [
            "[1] SELECT id, name FROM users",
            "    120 row(s) returned",
            "    0.012s",
            "",
            "[2] UPDATE orders SET status = 'paid'",
            "    OK, 12 row(s) affected",
            "    NOTICE: trigger fired",
            "    0.004s",
            "",
            "[3] SELECT * FROM nope",
            "    Cancelled",
            "",
            "The open transaction was not committed.",
        ])
    }

    @Test("A failure's message keeps its lines, indented under the statement")
    func failureMessageIsIndented() {
        let log = QueryRunLog(startedAt: .now, entries: [
            .failed(Self.failing, message: "Statement 3/4 failed: boom\nOutput before the error:\nline"),
        ])

        #expect(log.messageText == """
            [1] SELECT * FROM nope
                Error: Statement 3/4 failed: boom
                Output before the error:
                line
            """)
    }

    @Test("A statement with no rows affected shows the server's status, or OK")
    func zeroAffectedShowsStatus() {
        let withStatus = QueryRunLogEntry(statement: "CREATE TABLE t (id int)", outcome: .affectedRows(0), statusMessage: "CREATE TABLE")
        let plain = QueryRunLogEntry(statement: "SET x = 1", outcome: .affectedRows(0))

        #expect(QueryRunLog.outcomeText(for: withStatus) == "CREATE TABLE")
        #expect(QueryRunLog.outcomeText(for: plain) == "OK")
        #expect(QueryRunLog(startedAt: .now, entries: [withStatus]).messageText == "[1] CREATE TABLE t (id int)\n    CREATE TABLE")
    }

    @Test("A long statement is shortened to one line")
    func longStatementIsShortened() {
        let statement = "SELECT\n  id,\n\tname\nFROM   users  "
        #expect(QueryRunLog.displayStatement(statement) == "SELECT id, name FROM users")

        let long = "SELECT " + String(repeating: "column_name, ", count: 40) + "1"
        let shown = QueryRunLog.displayStatement(long)
        #expect(shown.count == QueryRunLog.statementCharacterLimit + 1)
        #expect(shown.hasSuffix("…"))
    }

    // MARK: - Page after a run

    @Test("The Message tab comes forward when a statement failed, the run stopped, or nothing returned rows")
    func pageAfterARun() {
        let rows = QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(3), resultSetId: UUID())
        let emptyRows = QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(0), resultSetId: UUID())
        let write = QueryRunLogEntry(statement: Self.update, outcome: .affectedRows(2), resultSetId: UUID())
        let plan = QueryRunLogEntry(statement: "EXPLAIN SELECT 1", outcome: .plan, resultSetId: UUID())
        let notShown = QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(3))

        func opensOnMessage(_ entries: [QueryRunLogEntry]) -> Bool {
            QueryRunLog(startedAt: .now, entries: entries).opensOnMessage
        }

        #expect(opensOnMessage([rows, write]) == false)
        #expect(opensOnMessage([emptyRows]) == false)
        #expect(opensOnMessage([plan]) == false)
        #expect(opensOnMessage([write]) == true)
        #expect(opensOnMessage([write, write]) == true)
        #expect(opensOnMessage([rows, .failed(Self.failing, message: "boom")]) == true)
        #expect(opensOnMessage([rows, .cancelled(Self.update)]) == true)
        #expect(opensOnMessage([notShown]) == true)
    }

    @Test("Installing a log brings the page the run calls for to the front")
    func installChoosesThePage() {
        var display = TabDisplayState()
        let later = ContinuousClock.now
        let earlier = later - .seconds(1)

        display.installRunLog(QueryRunLog(startedAt: earlier, entries: [
            QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(1), resultSetId: UUID()),
        ]))
        #expect(display.resultsPage == .result)

        display.installRunLog(QueryRunLog(startedAt: later, entries: [.failed(Self.failing, message: "boom")]))
        #expect(display.resultsPage == .message)
        #expect(display.runLog?.entries.first?.outcome == .failed(message: "boom"))
    }

    @Test("A run that ends after a later one started does not cover the later run's log")
    func olderRunIsRefused() {
        var display = TabDisplayState()
        let later = ContinuousClock.now
        let earlier = later - .seconds(1)
        let newer = QueryRunLog(startedAt: later, entries: [
            QueryRunLogEntry(statement: Self.select, outcome: .returnedRows(1), resultSetId: UUID()),
        ])
        display.installRunLog(newer)

        let stale = QueryRunLog(startedAt: earlier, entries: [.cancelled(Self.update)])
        #expect(display.admitsRunLog(stale) == false)
        display.installRunLog(stale)

        #expect(display.runLog == newer)
        #expect(display.resultsPage == .result)
    }

    @Test("Replacing a result in place moves the log's pointer to the new one")
    func replaceResultMovesTheLogPointer() {
        var display = TabDisplayState()
        let original = rowsResult(rowCount: 1)
        display.replaceUnpinnedResults(with: [original])
        display.installRunLog(QueryRunLog(startedAt: .now, entries: [
            QueryRunLogEntry(statement: Self.select, resultSet: original),
        ]))

        let reread = rowsResult(rowCount: 2)
        display.replaceResult(original.id, with: reread)

        #expect(display.runLog?.entries.first?.resultSetId == reread.id)
    }
}
