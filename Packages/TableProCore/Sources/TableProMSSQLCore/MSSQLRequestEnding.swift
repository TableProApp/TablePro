import Foundation

/// How a read that stops before the end of its request ends the rest of it on the server.
///
/// db-lib ends a request one of two ways, and leaving the rest unread is not a third. An attention (`dbcancel`) ends
/// the statement on the server at once. Reading the rest costs as long as the server takes to send it. A request left
/// unread stays suspended on the server holding its locks: measured, a `SELECT` stopped after 10,000 of 200,000 rows
/// held its locks until another session's `ALTER TABLE` gave up with Msg 1222, and the connection's next call had to
/// read every remaining row before the server answered it, 22 seconds for 3 million and never for a runaway cross join.
///
/// An attention is an abort to the server, though. Under `SET XACT_ABORT ON` it rolls back the session's open
/// transaction with no message to either handler, measured after 10,000 of 200,000 rows, while with `XACT_ABORT` off
/// the transaction and its work survive. So the driver asks the session before a read it may stop early, and reads the
/// rest only in the one state where an attention would throw work away, or when the session did not say.
public enum MSSQLRequestEnding: Sendable, Equatable {
    case attention
    case readRest

    /// Bit 16384 of `@@OPTIONS` is `XACT_ABORT`. It is a request of its own rather than a statement in front of the
    /// read, so the read's results, and the plans `SET STATISTICS XML ON` adds to them, reach the reader untouched.
    public static let sessionQuery = "SELECT @@TRANCOUNT, @@OPTIONS & 16384"

    /// The ending the session's answer to `sessionQuery` allows. A missing or unreadable answer, such as the plan a
    /// session under `SET SHOWPLAN_XML ON` returns instead, reads the rest.
    public init(sessionAnswer: MSSQLRawResult?) {
        guard let row = sessionAnswer?.rows.first, row.count >= 2,
              let openTransactions = Self.integer(row[0]),
              let xactAbort = Self.integer(row[1])
        else {
            self = .readRest
            return
        }
        self = openTransactions > 0 && xactAbort != 0 ? .readRest : .attention
    }

    private static func integer(_ cell: MSSQLRawCell) -> Int? {
        cell.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
