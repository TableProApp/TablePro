//
//  SqlBlockStructure.swift
//  TablePro
//

import Foundation

/// The word level rules for the blocks a semicolon does not end.
///
/// A routine body written `BEGIN ... END` holds semicolons that separate the statements inside it, not the routine
/// from whatever follows it. Every scanner that walks a script has to agree on which words open and close those
/// blocks, or the same text splits one way for execution and another way for folding, and the editor ends up offering
/// to run a fragment. ``SQLStatementScanner`` and ``SQLFoldScanner`` both read the vocabulary from here for that
/// reason, including the `END IF` disambiguation that is easy to get subtly different twice.
///
/// What they do not share is how much they will let a block swallow: see `allowsBlock` on ``effect(of:endingAt:in:length:allowsBlock:)``.
///
/// This sits beside ``SqlLexer`` rather than inside it because these rules are about words, not characters.
enum SqlBlockStructure {
    /// What a keyword does to the block nesting around it.
    enum Effect {
        case opensBlock
        case closesBlock
        case none
    }

    /// The keywords that follow `BEGIN` when it starts a transaction rather than a block.
    ///
    /// `BEGIN;` and `BEGIN TRANSACTION;` are statements in their own right on PostgreSQL, MySQL and SQLite, and
    /// reading either as a block opener merges every statement that follows into one. `TRAN` and `DISTRIBUTED` are
    /// here because T-SQL abbreviates, and inside a routine body an unmatched `BEGIN TRAN` swallows everything after
    /// the routine. `BEGIN ATOMIC` is deliberately absent, because that one does open a routine body.
    private static let transactionFollowers: Set<String> = [
        "TRANSACTION", "TRAN", "DISTRIBUTED", "WORK", "DEFERRED", "IMMEDIATE", "EXCLUSIVE", "ISOLATION", "READ", "NOT",
    ]

    /// The keywords that follow `END` when it closes a construct nothing here opened.
    ///
    /// `END CASE` is absent on purpose: `CASE` opens a block, so its `END` has to close one.
    private static let controlFlowFollowers: Set<String> = ["IF", "LOOP", "WHILE", "FOR", "REPEAT"]

    /// The keywords a statement has to open with before a `BEGIN` inside it is read as a routine body.
    ///
    /// Only ``SQLStatementScanner`` consults this, and the reason is safety rather than grammar. An anonymous
    /// `BEGIN ... END` block is real SQL, and folding one is right. Splitting on one is not: a `BEGIN` that swallowed
    /// the statements after it would hand the execution gate a single statement whose first word is `BEGIN`, and
    /// `QueryClassifier` tiers a statement by its leading keyword, so a swallowed `DROP` would be classified safe and
    /// run under Read-Only with no confirmation. Folding cannot execute anything, so it takes every block.
    private static let routineDefinitionOpeners: Set<String> = ["CREATE", "ALTER", "REPLACE", "DECLARE"]

    /// Whether a statement opening with `keyword` can carry a `BEGIN ... END` body.
    static func opensRoutineDefinition(_ keyword: String) -> Bool {
        routineDefinitionOpeners.contains(keyword)
    }

    /// The keyword at `offset`, uppercased, and the offset just past it.
    ///
    /// Returns an empty string when `offset` does not start an identifier, along with the next offset, so a caller can
    /// advance one character and carry on without a second bounds check.
    static func readKeyword(_ text: NSString, at offset: Int, length: Int) -> (text: String, end: Int) {
        guard offset < length, SqlDollarQuote.isIdentifierStart(text.character(at: offset)) else {
            return ("", offset + 1)
        }
        var cursor = offset
        var scalars = String.UnicodeScalarView()
        while cursor < length, SqlDollarQuote.isIdentifierPart(text.character(at: cursor)) {
            if let scalar = UnicodeScalar(text.character(at: cursor)) {
                scalars.append(scalar)
            }
            cursor += 1
        }
        return (String(scalars).uppercased(), cursor)
    }

    /// What `keyword`, which ends at `wordEnd`, does to the block nesting.
    ///
    /// - Parameter allowsBlock: whether a block may open here at all. Folding passes `true`, because an anonymous
    ///   `BEGIN ... END` is foldable and folding executes nothing. Splitting passes ``opensRoutineDefinition(_:)`` for
    ///   the statement's first keyword, for the reason given on `routineDefinitionOpeners`.
    static func effect(
        of keyword: String,
        endingAt wordEnd: Int,
        in text: NSString,
        length: Int,
        allowsBlock: Bool
    ) -> Effect {
        guard allowsBlock else { return .none }

        switch keyword {
        case "BEGIN":
            return startsTransaction(after: wordEnd, in: text, length: length) ? .none : .opensBlock
        case "CASE":
            return .opensBlock
        case "END":
            return closesControlFlow(after: wordEnd, in: text, length: length) ? .none : .closesBlock
        default:
            return .none
        }
    }

    // MARK: - Private

    private static func startsTransaction(after offset: Int, in text: NSString, length: Int) -> Bool {
        let cursor = skipTrivia(from: offset, in: text, length: length)
        guard cursor < length else { return true }
        guard text.character(at: cursor) != SqlLexer.semicolon else { return true }
        return transactionFollowers.contains(readKeyword(text, at: cursor, length: length).text)
    }

    private static func closesControlFlow(after offset: Int, in text: NSString, length: Int) -> Bool {
        let cursor = skipTrivia(from: offset, in: text, length: length)
        guard cursor < length else { return false }
        return controlFlowFollowers.contains(readKeyword(text, at: cursor, length: length).text)
    }

    private static func skipTrivia(from offset: Int, in text: NSString, length: Int) -> Int {
        var cursor = offset
        while cursor < length {
            if SqlLexer.isWhitespace(text.character(at: cursor)) {
                cursor += 1
                continue
            }
            if SqlLexer.startsLineComment(text, at: cursor, length: length) {
                cursor = SqlLexer.endOfLine(text, from: cursor, length: length)
                continue
            }
            if SqlLexer.startsBlockComment(text, at: cursor, length: length) {
                cursor = SqlLexer.skipBlockComment(text, from: cursor, length: length).next
                continue
            }
            break
        }
        return cursor
    }
}
