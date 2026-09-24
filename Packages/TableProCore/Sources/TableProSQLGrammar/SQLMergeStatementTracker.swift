import Foundation

/// Whether the `;` that ends a statement ends a T-SQL `MERGE`, which the server refuses to run without it.
///
/// Measured on Azure SQL Edge 15.0: a `MERGE` sent without its `;` fails its whole batch with Msg 10713 alone, after a
/// `WITH`, `IF`, `ELSE`, `WHILE` or `DECLARE`, after a statement written without a `;`, and as a procedure's body.
/// Inside parentheses, as the rows an `INSERT` reads, it needs none, and neither do the hints `INNER MERGE JOIN` and
/// `OPTION (MERGE JOIN)` or `ALTER PARTITION FUNCTION ... MERGE RANGE`. `MERGE` is reserved, so a bare `merge` is never
/// a name, while `@merge`, `#merge`, `x$merge` and `émerge` are. `1MERGE` and `1.MERGE` are a number and a `MERGE`.
/// `scripts/check-mssql-merge-terminator.sh` measures it again.
struct SQLMergeStatementTracker {
    private static let at = UInt16(UnicodeScalar("@").value)
    private static let nameJoiners: Set<UInt16> = [at, SqlLexer.hash, SqlDollarQuote.dollar]

    /// The words after `MERGE` that make it part of a clause rather than a statement.
    private static let clauseFollowers: Set<String> = ["JOIN", "UNION", "RANGE"]

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

    /// Whether a word right after `symbol` continues a name, as it does after `@`, `#`, `$` or a letter outside ASCII.
    /// Half of a character outside the Basic Multilingual Plane cannot be told from a letter here, so it counts as one.
    private static func joinsName(_ symbol: UInt16) -> Bool {
        if nameJoiners.contains(symbol) { return true }
        guard symbol >= 0x80 else { return false }
        return Unicode.Scalar(symbol)?.properties.isAlphabetic ?? true
    }
}
