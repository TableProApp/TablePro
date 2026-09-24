import Foundation

/// What one batch answered with, sent in one request and read to its end.
///
/// SQL Server scopes a local variable, a table variable and a `TRY...CATCH` to the batch that declares it, so a script
/// only means what its author wrote when each batch reaches the server whole. One batch can then return any number of
/// result sets, and the server carries on past most errors inside it, so an error arrives between result sets rather
/// than instead of them.
public struct PluginBatchResult: Sendable {
    /// Every result set the batch returned complete, in the order the server sent them, each with its own columns.
    /// A result set an error interrupted is not here: its rows are not the answer to its statement.
    public let resultSets: [PluginQueryResult]

    /// The rows the statements that return no result set reported. Zero when none reported a count.
    public let rowsAffected: Int

    /// The errors the server raised while running the batch, in the order it raised them.
    public let errors: [PluginBatchError]

    /// Result sets the driver read past and dropped because the batch returned more than it keeps.
    public let discardedResultSetCount: Int

    public let executionTime: TimeInterval

    public init(
        resultSets: [PluginQueryResult],
        rowsAffected: Int,
        errors: [PluginBatchError],
        discardedResultSetCount: Int,
        executionTime: TimeInterval
    ) {
        self.resultSets = resultSets
        self.rowsAffected = rowsAffected
        self.errors = errors
        self.discardedResultSetCount = discardedResultSetCount
        self.executionTime = executionTime
    }
}

/// One error the server raised inside a batch.
public struct PluginBatchError: Sendable, Equatable {
    public let message: String

    /// The engine's own number for the error, such as SQL Server's `Msg 208`.
    public let code: Int?

    /// The 1-based line the server reported. It counts from the start of the batch, or from the start of `procedure`
    /// when the error was raised inside one.
    public let line: Int?

    /// The routine the error was raised in, when it was not raised by the batch's own text.
    public let procedure: String?

    /// How many of the batch's `resultSets` arrived before this error.
    public let precedingResultSetCount: Int

    public init(
        message: String,
        code: Int?,
        line: Int?,
        procedure: String?,
        precedingResultSetCount: Int
    ) {
        self.message = message
        self.code = code
        self.line = line
        self.procedure = procedure
        self.precedingResultSetCount = precedingResultSetCount
    }
}
