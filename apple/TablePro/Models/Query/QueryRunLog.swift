//
//  QueryRunLog.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What one statement of a run came to. A row set counts as rows returned even when it is empty: the
/// statement answered with columns, so its result is a grid rather than a count.
enum QueryStatementOutcome: Equatable, Sendable {
    case returnedRows(Int)
    case affectedRows(Int)
    case plan
    case failed(message: String)
    case cancelled

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One statement or batch of a run, as the Message and Summary tabs report it.
///
/// A copy of the facts rather than a reference to the `ResultSet`: a page turn or a sort rebuilds the
/// result, and the log describes the run as it ended.
struct QueryRunLogEntry: Equatable, Identifiable, Sendable {
    /// The position in the run, from 1. Set by `QueryRunLog`, which numbers its entries.
    var ordinal = 0
    let statement: String
    let outcome: QueryStatementOutcome
    var executionTime: TimeInterval?
    var statusMessage: String?
    var serverOutput: PluginServerOutput = .none
    /// The result this statement produced, so a Summary row can open it. Nil for a statement whose
    /// result was never installed: a stopped run keeps the previous results on screen.
    var resultSetId: UUID?

    var id: Int { ordinal }

    init(
        statement: String,
        outcome: QueryStatementOutcome,
        executionTime: TimeInterval? = nil,
        statusMessage: String? = nil,
        serverOutput: PluginServerOutput = .none,
        resultSetId: UUID? = nil
    ) {
        self.statement = statement
        self.outcome = outcome
        self.executionTime = executionTime
        self.statusMessage = statusMessage
        self.serverOutput = serverOutput
        self.resultSetId = resultSetId
    }

    @MainActor
    init(statement: String, resultSet: ResultSet) {
        let outcome: QueryStatementOutcome
        if let error = resultSet.errorMessage {
            outcome = .failed(message: error)
        } else if resultSet.isExplainResult {
            outcome = .plan
        } else if resultSet.resultColumns.isEmpty {
            outcome = .affectedRows(resultSet.rowsAffected)
        } else {
            outcome = .returnedRows(resultSet.tableRows.count)
        }
        self.init(
            statement: statement,
            outcome: outcome,
            executionTime: resultSet.executionTime,
            statusMessage: resultSet.statusMessage,
            serverOutput: resultSet.serverOutput,
            resultSetId: resultSet.id
        )
    }

    /// A statement that ran in a run whose results were not installed, so it points at no result.
    init(statement: String, result: QueryResult) {
        self.init(
            statement: statement,
            outcome: result.columns.isEmpty ? .affectedRows(result.rowsAffected) : .returnedRows(result.rows.count),
            executionTime: result.executionTime,
            statusMessage: result.statusMessage,
            serverOutput: result.serverOutput
        )
    }

    static func failed(_ statement: String, message: String, resultSetId: UUID? = nil) -> Self {
        QueryRunLogEntry(statement: statement, outcome: .failed(message: message), resultSetId: resultSetId)
    }

    static func cancelled(_ statement: String) -> Self {
        QueryRunLogEntry(statement: statement, outcome: .cancelled)
    }
}

/// How a run that sends its statements or batches one at a time ended.
enum QueryRunEnding: Equatable {
    case completed
    /// `statement` is nil when the run failed outside any statement: the connection, the transaction's start or its commit.
    case failed(statement: String?, message: String, resultSetId: UUID?)
    /// Stopped, or ended by something other than its own completion, before the next statement finished.
    case stopped
}

/// What the last run in a query tab did, statement by statement. Kept on the tab in memory and replaced by each run.
struct QueryRunLog: Equatable, Sendable {
    /// When the run's claim was taken, so a run that ends late never covers the log of one that started after it.
    let startedAt: ContinuousClock.Instant
    let entries: [QueryRunLogEntry]
    /// A note about the run as a whole, such as a transaction it left open.
    let notice: String?

    init(startedAt: ContinuousClock.Instant, entries: [QueryRunLogEntry], notice: String? = nil) {
        self.startedAt = startedAt
        self.entries = entries.enumerated().map { index, entry in
            var numbered = entry
            numbered.ordinal = index + 1
            return numbered
        }
        self.notice = notice?.isEmpty == true ? nil : notice
    }

    /// The Message tab is the answer when the run failed, stopped or returned no rows to look at. Otherwise
    /// the result the run made active stays in front, as it does with the tabs off.
    var opensOnMessage: Bool {
        let interrupted = entries.contains { entry in
            switch entry.outcome {
            case .failed, .cancelled: return true
            case .returnedRows, .affectedRows, .plan: return false
            }
        }
        guard !interrupted else { return true }
        return !entries.contains { entry in
            switch entry.outcome {
            case .returnedRows, .plan: return entry.resultSetId != nil
            case .affectedRows, .failed, .cancelled: return false
            }
        }
    }

    func resultSetId(ofEntry ordinal: Int) -> UUID? {
        entries.first { $0.ordinal == ordinal }?.resultSetId
    }

    /// A re-read swaps a result for a new one under the same tab, so the entry that produced it follows.
    func replacingResult(_ outgoingId: UUID, with incomingId: UUID) -> QueryRunLog {
        guard entries.contains(where: { $0.resultSetId == outgoingId }) else { return self }
        let moved = entries.map { entry in
            guard entry.resultSetId == outgoingId else { return entry }
            var copy = entry
            copy.resultSetId = incomingId
            return copy
        }
        return QueryRunLog(startedAt: startedAt, entries: moved, notice: notice)
    }

    /// The entries of a run that sends `statements` one at a time, of which `finished` ran to the end in order.
    /// A stop names the statement it interrupted; the statements after it never ran and are left out.
    static func entries(
        statements: [String],
        finished: [QueryRunLogEntry],
        ending: QueryRunEnding
    ) -> [QueryRunLogEntry] {
        switch ending {
        case .completed:
            return finished
        case let .failed(statement, message, resultSetId):
            return finished + [.failed(statement ?? "", message: message, resultSetId: resultSetId)]
        case .stopped:
            guard statements.indices.contains(finished.count) else { return finished }
            return finished + [.cancelled(statements[finished.count])]
        }
    }
}

// MARK: - Text

extension QueryRunLog {
    static let statementCharacterLimit = 200
    private static let indent = "    "

    /// The Message tab's text: each statement, what it came to, what it printed and how long it took.
    var messageText: String {
        var blocks = entries.map(Self.messageBlock(for:))
        if let notice {
            blocks.append(notice)
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func messageBlock(for entry: QueryRunLogEntry) -> String {
        var lines: [String] = []
        let statement = displayStatement(entry.statement)
        lines.append(statement.isEmpty ? "[\(entry.ordinal)]" : "[\(entry.ordinal)] \(statement)")
        lines += indented(outcomeText(for: entry))
        if let status = entry.statusMessage, !status.isEmpty, status != outcomeText(for: entry) {
            lines += indented(status)
        }
        lines += entry.serverOutput.lines.map { indent + $0 }
        if entry.serverOutput.isTruncated {
            lines.append(indent + String(localized: "The output was cut short."))
        }
        if let time = entry.executionTime {
            lines.append(indent + timeText(time))
        }
        return lines.joined(separator: "\n")
    }

    private static func indented(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { indent + $0 }
    }

    /// One line, with runs of whitespace collapsed and a long statement cut short.
    static func displayStatement(_ statement: String) -> String {
        let collapsed = statement
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return ResultSetMenuModel.truncated(collapsed, limit: statementCharacterLimit)
    }

    static func outcomeText(for entry: QueryRunLogEntry) -> String {
        switch entry.outcome {
        case .returnedRows(let count):
            return String(format: String(localized: "%lld row(s) returned"), Int64(count))
        case .affectedRows(let count):
            if count == 0, let status = entry.statusMessage, !status.isEmpty {
                return status
            }
            guard count > 0 else { return String(localized: "OK") }
            return String(format: String(localized: "OK, %lld row(s) affected"), Int64(count))
        case .plan:
            return String(localized: "Query plan returned")
        case .failed(let message):
            return String(format: String(localized: "Error: %@"), message)
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    static func statusText(for outcome: QueryStatementOutcome) -> String {
        switch outcome {
        case .returnedRows, .affectedRows, .plan:
            return String(localized: "OK")
        case .failed:
            return String(localized: "Error")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    /// Rows returned or affected, as the Summary's Rows column shows them. Nil when the statement reported neither.
    static func rowCount(for outcome: QueryStatementOutcome) -> Int? {
        switch outcome {
        case .returnedRows(let count), .affectedRows(let count):
            return count
        case .plan, .failed, .cancelled:
            return nil
        }
    }

    static func timeText(_ time: TimeInterval) -> String {
        String(format: "%.3fs", time)
    }
}

/// Which page of a query tab's results pane is in front while the Message and Summary tabs are on.
enum ResultsPage: Equatable, Sendable {
    case message
    case summary
    case result
}
