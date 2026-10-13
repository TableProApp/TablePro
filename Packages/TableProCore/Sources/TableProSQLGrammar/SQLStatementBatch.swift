import Foundation

/// The statements the server receives in one request, and the text they are sent as.
///
/// SQL Server scopes a local variable, a table variable and a `TRY...CATCH` to one batch, and its own tools cut a script
/// into batches only at a line holding `GO`. A text with no such line is one batch, and only a driver that sends
/// batches whole runs it as one: every other run takes its statements one by one.
public struct SQLStatementBatch: Sendable {
    /// The source between the first statement's start and the last one's end, inner `;` and comments included.
    public let sql: String

    /// The statements inside, in the caller's coordinates, as the statement scanner found them.
    public let statements: [SQLStatementScanner.ExecutableStatement]

    /// How many times the script asks for the batch to run: `GO 5` runs it five times.
    public let repeatCount: Int

    public init(sql: String, statements: [SQLStatementScanner.ExecutableStatement], repeatCount: Int) {
        self.sql = sql
        self.statements = statements
        self.repeatCount = repeatCount
    }

    /// The batch's span in the caller's coordinates.
    public var range: NSRange {
        guard let first = statements.first, let last = statements.last else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
    }
}

public extension SQLStatementScanner {
    /// Groups a scanned text's statements into the batches its engine runs.
    ///
    /// `statements` and `separators` are in `text`'s coordinates; the batches come back shifted by `sourceOffset`, the
    /// way a run started from a selection already shifts its statements onto the whole document.
    static func batches(
        in text: String,
        statements: [ExecutableStatement],
        separators: [SQLBatchSeparator],
        sourceOffset: Int = 0
    ) -> [SQLStatementBatch] {
        let source = text as NSString
        var batches: [SQLStatementBatch] = []
        var pending: [ExecutableStatement] = []
        var remaining = statements[...]

        func close(repeatCount: Int) {
            guard let first = pending.first, let last = pending.last else { return }
            let span = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
            batches.append(
                SQLStatementBatch(
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
