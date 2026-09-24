import Foundation

/// One message the server sent while running a request, as db-lib's message handler receives it.
///
/// Severity decides what it is. Above 10 it is an error, and a batch goes on past most of them, so an error is known
/// only from the message: `dbresults` returns `SUCCEED` for a `SELECT 1/0` whose error arrived with its columns, and
/// `dbnextrow` returns `NO_MORE_ROWS` for a scan a conversion error cut short. At 20 and above the server has ended
/// the connection, measured with `RAISERROR(..., 20, 1) WITH LOG`: the batch read completes normally and the next
/// request on that connection fails with db-lib 20017.
public struct MSSQLServerMessage: Sendable, Equatable {
    public let number: Int
    public let severity: Int
    public let state: Int

    /// 1-based, counted from the start of the batch, or of `procedure` when the message came from inside one. Zero
    /// when the server gave none.
    public let line: Int

    /// Empty when the message came from the batch's own text.
    public let procedure: String

    public let text: String

    public init(number: Int, severity: Int, state: Int, line: Int, procedure: String, text: String) {
        self.number = number
        self.severity = severity
        self.state = state
        self.line = line
        self.procedure = procedure
        self.text = text
    }

    public var isError: Bool {
        severity > 10
    }

    public var endsConnection: Bool {
        severity >= 20
    }

    /// What the batch printed: `PRINT`, `RAISERROR` at severity 10 or below, and the server's own notices such as
    /// "The statement has been terminated." A change of database, language or character set is left out, because the
    /// server sends one on every login and every `USE` whether or not the script asked to hear about it.
    public var isOutput: Bool {
        !isError && !Self.contextChangeNumbers.contains(number)
    }

    /// 5701 "Changed database context", 5703 "Changed language setting", 5704 "Changed client character set".
    /// Measured on Azure SQL Edge 15.0: 5701 and 5703 arrive on login, 5701 again on every `USE`.
    private static let contextChangeNumbers: Set<Int> = [5_701, 5_703, 5_704]
}

/// db-lib's own error numbers, which reach the error handler rather than the message handler.
public enum MSSQLLibraryError {
    /// `SYBESMSG`, "General SQL Server error: Check messages from the SQL Server". db-lib raises it after every server
    /// error, so it repeats the message the message handler already received and carries nothing of its own.
    public static let serverMessageNotice = 20_018

    /// The numbers that mean the connection is gone: a failed read (`SYBEREAD`) or write (`SYBEWRIT`), an unexpected
    /// end of stream (`SYBESEOF`), and a DBPROCESS db-lib has already marked dead (`SYBEDDNE`). Measured after a
    /// severity 20 error closed the session: the next request raised 20017 and then 20047.
    public static func endsConnection(_ number: Int) -> Bool {
        connectionEndingNumbers.contains(number)
    }

    private static let connectionEndingNumbers: Set<Int> = [20_004, 20_006, 20_017, 20_047]
}

/// A server error and where it arrived among the result sets of the batch that raised it.
public struct MSSQLPlacedError: Sendable, Equatable {
    public let message: MSSQLServerMessage

    /// How many complete result sets the read had kept when the error arrived.
    public let precedingResultSetCount: Int

    public init(message: MSSQLServerMessage, precedingResultSetCount: Int) {
        self.message = message
        self.precedingResultSetCount = precedingResultSetCount
    }
}

/// Everything one request answered with, read to its end.
public struct MSSQLBatchReadout: Sendable {
    /// The result sets the batch returned complete, in arrival order, each with its own columns.
    public let resultSets: [MSSQLRawResult]

    /// The counts statements without a result set reported. A count db-lib reports as -1 means there was none.
    public let rowsAffected: Int

    /// The first errors the request raised, up to the number a read keeps.
    public let errors: [MSSQLPlacedError]

    /// Errors the request raised past the ones kept, counted rather than stored so a loop failing on every pass cannot
    /// grow a read without bound.
    public let errorsNotKept: Int

    /// Complete result sets the read went past without keeping, because it had kept as many as it keeps.
    public let resultSetsReadPast: Int

    public init(
        resultSets: [MSSQLRawResult],
        rowsAffected: Int,
        errors: [MSSQLPlacedError],
        errorsNotKept: Int,
        resultSetsReadPast: Int
    ) {
        self.resultSets = resultSets
        self.rowsAffected = rowsAffected
        self.errors = errors
        self.errorsNotKept = errorsNotKept
        self.resultSetsReadPast = resultSetsReadPast
    }
}

public extension MSSQLBatchReadout {
    /// The answer a call that returns one result gives: the first result set with its own columns, or the summed counts
    /// when the request returned none. Any server error fails the call, because a caller that gets one result has no
    /// place to show an error beside it.
    func singleResult() throws -> MSSQLRawResult {
        if let error = errors.first {
            throw MSSQLCoreError.queryFailed(error.message.text)
        }
        guard let first = resultSets.first else {
            return MSSQLRawResult(columns: [], rows: [], affectedRows: rowsAffected, isTruncated: false)
        }
        return MSSQLRawResult(
            columns: first.columns,
            rows: first.rows,
            affectedRows: first.rows.count,
            isTruncated: first.isTruncated,
            resultSetsNotShown: resultSets.count - 1 + resultSetsReadPast
        )
    }
}
