import Foundation

/// What the `;` that ends a statement is to that statement.
public enum SQLStatementTerminator: Equatable, Sendable {
    /// It separates the statement from the next one, and the driver never sees it.
    case separator

    /// It belongs to the statement's own grammar. A PL/SQL unit ends in `END;`, and measured on Oracle 23ai a block
    /// sent without that `;` fails with PLS-00103 while a `CREATE PROCEDURE` sent without it is stored INVALID. SQL
    /// Server fails a batch whose `MERGE` has no `;` with Msg 10713.
    case partOfStatement
}

/// Decides where a statement ends, one token at a time.
///
/// Every reader that divides a script into statements feeds the same tracker, so the editor, folding and SQL import
/// cannot disagree about where a statement stops or what reaches the driver. The API is forward only: a token that
/// depends on the one after it, such as a `BEGIN` that may start a transaction or an `END` that may close an `IF`, is
/// settled when that next token arrives. That is what lets the streaming import parser feed it across chunk
/// boundaries without looking ahead.
///
/// Words arrive uppercased. Whitespace and comments arrive as ``observeGap()``; a string literal, a quoted identifier
/// or a dollar-quoted body arrives as ``observeOpaqueToken()``.
public protocol SQLStatementBoundaryTracking {
    /// Whether words still bear on where this statement ends. A reader that has to assemble words itself can stop
    /// doing so once this is false, which keeps a plain `INSERT` dump free of the cost.
    var needsWords: Bool { get }

    var terminator: SQLStatementTerminator { get }

    /// Whether a `:name` in this statement can be a bind parameter. It cannot in a definition: Oracle refuses bind
    /// variables in DDL, and inside a trigger body `:NEW` and `:OLD` are pseudo-records.
    var acceptsBindParameters: Bool { get }

    mutating func observeWord(_ word: String)
    mutating func observeSymbol(_ symbol: UInt16)
    mutating func observeOpaqueToken()

    /// Whitespace or a comment between two tokens, which keeps a word from continuing the name before it: `x$MERGE`
    /// is one name in T-SQL, while `x$` and `MERGE` on the next line are a name and a statement.
    mutating func observeGap()

    /// Returns whether this `;` ends the statement.
    mutating func observeSemicolon() -> Bool

    mutating func reset()
}

public enum SQLStatementBoundaries {
    /// The one place a grammar is matched to its statement boundaries, so no reader can pick a different one.
    public static func makeTracker(for grammar: SQLLexicalGrammar) -> any SQLStatementBoundaryTracking {
        guard grammar.contains(.plsqlBlocks) else { return SQLRoutineBodyTracker(grammar: grammar) }
        return PLSQLUnitTracker()
    }

    /// Whether a statement `grammar` reads can own the `;` that ends it: a PL/SQL unit's, or a T-SQL `MERGE`'s. A
    /// reader that ends a statement at every `;` and drops it is only right where none can.
    public static func statementsCanOwnTerminator(in grammar: SQLLexicalGrammar) -> Bool {
        !grammar.isDisjoint(with: [.plsqlBlocks, .terminatedMergeStatements])
    }
}
