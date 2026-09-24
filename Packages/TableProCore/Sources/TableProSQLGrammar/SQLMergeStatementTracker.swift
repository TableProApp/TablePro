import Foundation

/// Whether the `;` that ends a statement ends a T-SQL `MERGE`, which the server refuses to run without it.
///
/// Measured on Azure SQL Edge 15.0: a `MERGE` sent without its `;` fails its whole batch with Msg 10713 alone, after a
/// `WITH`, `IF`, `ELSE`, `WHILE` or `DECLARE`, after a statement written without a `;`, and as a procedure's body.
/// Inside parentheses, as the rows an `INSERT` reads, it needs none, and neither do the hints `INNER MERGE JOIN` and
/// `OPTION (MERGE JOIN)`. `MERGE` is reserved, so a bare `merge` is never a name, while `@merge`, `#merge`, `x$merge`
/// and `émerge` are; `x$` or `注文` and a `MERGE` after a space or a comment are a name and a statement. `1MERGE` and
/// `1.MERGE` are a number and a `MERGE`. `RANGE` is not reserved, so `MERGE range AS t ...` is a statement on a table
/// named `range`, and the `;` kept after `ALTER PARTITION FUNCTION ... MERGE RANGE (2)` for it is one the server
/// accepts after any statement. `scripts/check-mssql-merge-terminator.sh` measures it again.
struct SQLMergeStatementTracker {
    private static let at = UInt16(UnicodeScalar("@").value)

    /// The words after `MERGE` that make it part of a clause rather than a statement. Both are reserved, so neither
    /// can be the name of the table a `MERGE` statement writes to.
    private static let clauseFollowers: Set<String> = ["JOIN", "UNION"]

    private var parenDepth = 0
    private var followsNameJoiner = false
    private var pendingMerge = false

    /// Whether a `;` read now ends a `MERGE`.
    private(set) var endsInMerge = false

    /// A `MERGE` inside parentheses needs no `;`, so no word there bears on it.
    var needsWords: Bool {
        parenDepth == 0
    }

    mutating func observeWord(_ word: String) {
        let continuesName = followsNameJoiner
        followsNameJoiner = false
        if pendingMerge {
            pendingMerge = false
            endsInMerge = endsInMerge || !Self.clauseFollowers.contains(word)
        }
        guard parenDepth == 0, !continuesName, word == "MERGE" else { return }
        pendingMerge = true
    }

    mutating func observeSymbol(_ symbol: UInt16) {
        settlePendingMerge()
        switch symbol {
        case SqlLexer.openParen:
            parenDepth += 1
        case SqlLexer.closeParen:
            parenDepth = max(0, parenDepth - 1)
        default:
            break
        }
        followsNameJoiner = Self.joinsName(symbol)
    }

    mutating func observeOpaqueToken() {
        settlePendingMerge()
        followsNameJoiner = false
    }

    mutating func observeGap() {
        followsNameJoiner = false
    }

    /// `endsStatement` is false for a `;` inside a routine body, which ends the `MERGE` before it there.
    mutating func observeSemicolon(endsStatement: Bool) {
        settlePendingMerge()
        followsNameJoiner = false
        if !endsStatement {
            endsInMerge = false
        }
    }

    // MARK: - Private

    private mutating func settlePendingMerge() {
        guard pendingMerge else { return }
        pendingMerge = false
        endsInMerge = true
    }

    /// Whether a word right after `symbol`, with no gap between them, continues a name, as it does after `@`, `#`,
    /// `$` or a letter outside ASCII.
    /// Half of a character outside the Basic Multilingual Plane cannot be told from a letter here, so it counts as one.
    private static func joinsName(_ symbol: UInt16) -> Bool {
        guard symbol >= 0x80 else { return symbol == at || symbol == SqlLexer.hash || symbol == SqlDollarQuote.dollar }
        return Unicode.Scalar(symbol)?.properties.isAlphabetic ?? true
    }
}
