//
//  TransactionEndStatement.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar
import TableProUtilities

// A statement that ends the session's transaction, by commit or by rollback: all Teradata takes after DDL.
internal enum TransactionEndStatement {
    private static let rollbackWords: Set<String> = ["ROLLBACK", "ABORT"]

    internal static func matches(_ statement: NSString, grammar: SQLLexicalGrammar) -> Bool {
        if BatchCommitStatement.matches(statement, grammar: grammar) { return true }
        var cursor = SQLTokenCursor(statement, grammar: grammar)
        guard let keyword = cursor.next()?.word, rollbackWords.contains(keyword) else { return false }
        // ROLLBACK TO SAVEPOINT keeps the transaction open.
        return cursor.next()?.word != "TO"
    }

    internal static func matches(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        matches(statement as NSString, grammar: grammar)
    }
}
