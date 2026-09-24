//
//  ExecutableBatch.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

/// The statements the server receives in one request, and the text they are sent as.
///
/// SQL Server scopes a local variable, a table variable and a `TRY...CATCH` to one batch, and its own tools cut a script
/// into batches only at a line holding `GO`. A text with no such line is one batch, and only a driver that sends
/// batches whole runs it as one: every other run takes its statements one by one.
struct ExecutableBatch: Sendable {
    /// The source between the first statement's start and the last one's end, inner `;` and comments included.
    let sql: String

    /// The statements inside, in tab coordinates, as the statement scanner found them.
    let statements: [SQLStatementScanner.ExecutableStatement]

    /// How many times the script asks for the batch to run: `GO 5` runs it five times.
    let repeatCount: Int

    /// The batch's span in tab coordinates.
    var range: NSRange {
        guard let first = statements.first, let last = statements.last else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
    }

    /// A routine definition takes no bind parameter, and SQL Server requires it to be alone in its batch.
    var acceptsBindParameters: Bool {
        statements.allSatisfy(\.acceptsBindParameters)
    }

    /// The batch's first statement, which is what the editor can find again: an anchor resolves by rescanning the
    /// text for the statement it names, and no statement spans a whole batch.
    var anchor: StatementAnchor? {
        statements.first.map(StatementAnchor.init)
    }
}

/// Groups a scanned text's statements into the batches its engine runs.
enum QueryBatchPlanner {
    /// `statements` and `separators` are in `text`'s coordinates; the batches come back shifted by `sourceOffset`
    /// onto the tab's whole query, the way a run started from a selection already shifts its statements.
    static func batches(
        in text: String,
        statements: [SQLStatementScanner.ExecutableStatement],
        separators: [SQLBatchSeparator],
        sourceOffset: Int
    ) -> [ExecutableBatch] {
        let source = text as NSString
        var batches: [ExecutableBatch] = []
        var pending: [SQLStatementScanner.ExecutableStatement] = []
        var remaining = statements[...]

        func close(repeatCount: Int) {
            guard let first = pending.first, let last = pending.last else { return }
            let span = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
            batches.append(
                ExecutableBatch(
                    sql: source.substring(with: span),
                    statements: pending.map { $0.offset(by: sourceOffset) },
                    repeatCount: repeatCount
                )
            )
            pending = []
        }

        for separator in separators {
            while let next = remaining.first, next.range.location < separator.range.location {
                pending.append(next)
                remaining = remaining.dropFirst()
            }
            close(repeatCount: separator.repeatCount)
        }
        pending.append(contentsOf: remaining)
        close(repeatCount: 1)
        return batches
    }
}

/// Which path a run takes, decided from its batches and from what the driver can do.
enum QueryExecutionRoute {
    /// One statement on the path that pages its rows, lets them be edited and streams them into the grid.
    case single(SQLStatementScanner.ExecutableStatement)
    /// Statement by statement, each in its own request.
    case statements([SQLStatementScanner.ExecutableStatement])
    /// Batch by batch, each sent whole.
    case batches([ExecutableBatch])
    /// A batch asks to run more than once with `GO n`, and the driver cannot send a batch whole to repeat it.
    case needsBatchDriver

    /// A driver that sends batches whole takes every run through them except a lone plain query, which keeps the
    /// single path for its paging and editing. A procedure call, a control-flow block or a write alone still runs as
    /// a batch, so every result set it returns is shown.
    ///
    /// A driver that cannot send batches runs statement by statement, and a `GO n` it cannot honour is refused rather
    /// than run once: expanding a count up to `Int32.max` into statements would stall the app before any of them ran.
    static func resolve(
        _ batches: [ExecutableBatch],
        sendsBatchesWhole: Bool,
        isPlainQuery: (String) -> Bool
    ) -> QueryExecutionRoute? {
        let statements = batches.flatMap(\.statements)
        guard let first = statements.first else { return nil }
        guard sendsBatchesWhole else {
            guard batches.allSatisfy({ $0.repeatCount == 1 }) else { return .needsBatchDriver }
            return statements.count == 1 ? .single(first) : .statements(statements)
        }
        if statements.count == 1, batches.first?.repeatCount == 1, isPlainQuery(first.sql) {
            return .single(first)
        }
        return .batches(batches)
    }
}
