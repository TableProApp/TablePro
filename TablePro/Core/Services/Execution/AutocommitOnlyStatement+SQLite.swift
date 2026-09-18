//
//  AutocommitOnlyStatement+SQLite.swift
//  TablePro
//

import Foundation

internal extension AutocommitOnlyStatement {
    /// SQLite 3.54.0, each statement run after `BEGIN`. `VACUUM` and a journal-mode or safety-level
    /// change are refused outright; `PRAGMA foreign_keys` is the quiet one, applying no change and
    /// reading back `0` after the `COMMIT` with no error at any point. `wal_checkpoint` is refused
    /// once the transaction has run anything, in every form.
    static func matchesSQLite(_ statement: NSString, rules: SQLLexicalRules) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "VACUUM", "DETACH":
            return true
        case "PRAGMA":
            return pragmaIsAutocommitOnly(&cursor)
        default:
            return false
        }
    }

    /// DuckDB v1.5.4. It takes `VACUUM`, `ATTACH`, `SET` and every `PRAGMA` inside a transaction,
    /// so it shares none of SQLite's rules despite sharing its lexing dialect. What it refuses is a
    /// checkpoint and a detach of a database the transaction has touched.
    static func matchesDuckDB(_ statement: NSString, rules: SQLLexicalRules) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "DETACH", "CHECKPOINT":
            return true
        case "FORCE":
            return cursor.next()?.word == "CHECKPOINT"
        case "CALL":
            return checkpointRoutines.contains(cursor.next()?.word ?? "")
                && cursor.next()?.isSymbol(SQLTokenCursor.openParen) == true
        default:
            return false
        }
    }
}

private extension AutocommitOnlyStatement {
    static let transactionScopedPragmas: Set<String> = ["JOURNAL_MODE", "FOREIGN_KEYS", "SYNCHRONOUS"]

    static let checkpointRoutines: Set<String> = ["CHECKPOINT", "FORCE_CHECKPOINT"]

    static func pragmaIsAutocommitOnly(_ cursor: inout SQLTokenCursor) -> Bool {
        guard var name = cursor.next()?.identifier else { return false }
        var following = cursor.next()
        if following?.isSymbol(SQLTokenCursor.period) == true {
            guard let qualified = cursor.next()?.identifier else { return false }
            name = qualified
            following = cursor.next()
        }
        if name == "WAL_CHECKPOINT" { return true }
        guard transactionScopedPragmas.contains(name), let following else { return false }
        return following.isSymbol(SQLTokenCursor.equals) || following.isSymbol(SQLTokenCursor.openParen)
    }
}
