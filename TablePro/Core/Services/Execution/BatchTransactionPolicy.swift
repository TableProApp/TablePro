//
//  BatchTransactionPolicy.swift
//  TablePro
//

import Foundation

/// How the app treats the transaction around a multi-statement run, decided from the text alone
/// before any driver is leased.
///
/// Three answers, in precedence order. A script that opens a transaction of its own or turns the
/// commit mode off manages its own, so the app opens none. A script holding a statement the engine
/// refuses inside a transaction block runs in autocommit. Everything else is wrapped, which is what
/// gives a failed batch its rollback.
///
/// An engine the app cannot open a transaction on at all
/// (``TransactionEngineFamily/wrapsBatchInTransaction``) never reaches the SQL rules, because they
/// are not its vocabulary: on Redis `SET autocommit 1` is a key write, not commit-mode control.
internal enum BatchTransactionPolicy {
    private static let commitModeScopes: Set<SQLSetAssignment.Scope> = [.unspecified, .session, .local]

    /// T-SQL writes no `=`: `SET IMPLICIT_TRANSACTIONS ON` and `SET ANSI_NULLS,
    /// IMPLICIT_TRANSACTIONS ON` are a comma list of option names followed by `ON` or `OFF`.
    /// `ANSI_DEFAULTS` turns `IMPLICIT_TRANSACTIONS` on with it.
    private static let implicitTransactionOptions: Set<String> = ["IMPLICIT_TRANSACTIONS", "ANSI_DEFAULTS"]

    internal static func plan(
        for statements: [String],
        databaseType: DatabaseType,
        rules: SQLLexicalRules
    ) -> BatchTransactionPlan {
        let family = TransactionEngineFamily.of(databaseType)
        guard family.wrapsBatchInTransaction else { return queuedBlockPlan(for: statements, rules: rules) }
        var runsInAutocommit = false
        var holdsASavepoint = false
        for statement in statements {
            let text = statement as NSString
            if takesTransactionControl(text, family: family, rules: rules) { return .scriptTransaction }
            if !runsInAutocommit, AutocommitOnlyStatement.matches(text, family: family, rules: rules) {
                runsInAutocommit = true
            }
            if family.savepointOpensTransaction, !holdsASavepoint, startsWithSavepoint(text, rules: rules) {
                holdsASavepoint = true
            }
        }
        guard runsInAutocommit else { return .appTransaction }
        return holdsASavepoint ? .scriptTransaction : .autocommit
    }

    /// The app opens nothing here, so the only question left is whether the script opens a block of
    /// its own. A `MULTI` does, and a batch that fails or is stopped inside one has to end it:
    /// nothing in the block has run, and the next command on that session would be queued into it
    /// rather than answered. The arm is unconditional because no Redis command reads `MULTI` as
    /// anything else.
    private static func queuedBlockPlan(
        for statements: [String],
        rules: SQLLexicalRules
    ) -> BatchTransactionPlan {
        let opensABlock = statements.contains { statement in
            var cursor = SQLTokenCursor(statement as NSString, rules: rules)
            return cursor.next()?.word == "MULTI"
        }
        return opensABlock ? .scriptTransaction : .autocommit
    }

    private static func takesTransactionControl(
        _ statement: NSString,
        family: TransactionEngineFamily,
        rules: SQLLexicalRules
    ) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        guard let keyword = cursor.next()?.word else { return false }
        switch keyword {
        case "BEGIN":
            return SqlBlockStructure.beginStartsTransaction(followedBy: cursor.next()?.word)
        case "START":
            return cursor.next()?.word == "TRANSACTION"
        case "XA":
            let following = cursor.next()?.word
            return following == "START" || following == "BEGIN"
        case "SET":
            return setsCommitMode(&cursor, family: family)
        default:
            return false
        }
    }

    /// `mysqlbinlog` writes `@@session.autocommit=1` as the fourth element of a `SET` list, so the
    /// MySQL family reads every element. PostgreSQL's `SET search_path TO a, b` is a list of values
    /// rather than of assignments, so everything else reads the first element only.
    private static func setsCommitMode(_ cursor: inout SQLTokenCursor, family: TransactionEngineFamily) -> Bool {
        guard family != .sqlServer else { return turnsOnImplicitTransactions(&cursor) }
        let assignments = SQLSetAssignments.assignments(from: &cursor, readsList: family == .mysql)
        return assignments.contains { $0.name == "AUTOCOMMIT" && commitModeScopes.contains($0.scope) }
    }

    private static func turnsOnImplicitTransactions(_ cursor: inout SQLTokenCursor) -> Bool {
        var namesTheCommitMode = false
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.comma) { continue }
            guard let word = token.word else { return false }
            if word == "ON" { return namesTheCommitMode }
            if word == "OFF" { return false }
            guard implicitTransactionOptions.contains(word) else { continue }
            namesTheCommitMode = true
        }
        return false
    }

    private static func startsWithSavepoint(_ statement: NSString, rules: SQLLexicalRules) -> Bool {
        var cursor = SQLTokenCursor(statement, rules: rules)
        return cursor.next()?.word == "SAVEPOINT"
    }
}
