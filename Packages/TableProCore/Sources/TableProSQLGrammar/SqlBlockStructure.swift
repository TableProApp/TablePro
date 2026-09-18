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
public enum SqlBlockStructure {
    /// What a keyword does to the block nesting around it.
    public enum Effect: Equatable, Sendable {
        case opensBlock
        /// Closes a block and swallows the keyword that follows up to `resumeAt`, which is how `END CASE` reads: the
        /// `CASE` names what is closing rather than opening another.
        case closesBlock(resumeAt: Int)
        case none
    }

    /// What an `END` means, given the word after it.
    public enum EndFollower: Equatable, Sendable {
        /// `END IF`, `END LOOP` and their kin close a construct that never opened a block, and the word is theirs.
        case closesControlFlow
        /// `END CASE` closes the `CASE` that opened a block, and the word is theirs.
        case closesCaseStatement
        /// Anything else closes a block and leaves the word to be read on its own, as the name in `END proc_name` is.
        case closesBlock
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
    /// `END CASE` is absent on purpose: `CASE` opens a block, so its `END` has to close one, and ``endingFollowedBy(_:)``
    /// gives it its own answer so the `CASE` after it is not read as a second opener.
    private static let controlFlowFollowers: Set<String> = ["IF", "LOOP", "WHILE", "FOR", "REPEAT"]

    /// The keywords a statement has to open with before a `BEGIN` inside it is read as a routine body.
    ///
    /// Only ``SQLRoutineBodyTracker`` consults this, and the reason is safety rather than grammar. An anonymous
    /// `BEGIN ... END` block is real SQL on some engines, and folding one is right. Splitting on one is not where the
    /// engine has no such block: a `BEGIN` that swallowed the statements after it would hand the execution gate a
    /// single statement whose first word is `BEGIN`, and `QueryClassifier` tiers a statement by its leading keyword,
    /// so a swallowed `DROP` would be tiered a plain write and skip the destructive confirmation. Folding cannot
    /// execute anything, so it takes every block. Oracle, whose anonymous blocks are the everyday form, has its own
    /// grammar in ``PLSQLUnitTracker`` and a classifier that reads the whole block.
    private static let routineDefinitionOpeners: Set<String> = ["CREATE", "ALTER", "REPLACE", "DECLARE"]

    /// Whether a statement opening with `keyword` can carry a `BEGIN ... END` body.
    public static func opensRoutineDefinition(_ keyword: String) -> Bool {
        routineDefinitionOpeners.contains(keyword)
    }

    public static func beginStartsTransaction(followedBy keyword: String?) -> Bool {
        guard let keyword else { return true }
        return transactionFollowers.contains(keyword)
    }

    public static func endingFollowedBy(_ keyword: String) -> EndFollower {
        if keyword == "CASE" { return .closesCaseStatement }
        return controlFlowFollowers.contains(keyword) ? .closesControlFlow : .closesBlock
    }

    /// The keyword at `offset`, uppercased, and the offset just past it.
    ///
    /// Returns an empty string when `offset` does not start an identifier, along with the next offset, so a caller can
    /// advance one character and carry on without a second bounds check.
    public static func readKeyword(_ text: NSString, at offset: Int, length: Int) -> (text: String, end: Int) {
        readKeyword(text, at: offset, length: length, grammar: [])
    }

    /// The keyword at `offset` as `grammar` spells identifiers.
    ///
    /// Oracle continues an identifier with `$` and `#`, so `V$SESSION` is one word, and starts a conditional
    /// compilation directive with `$`, so `$END` is one word that ``PLSQLUnitTracker`` can tell apart from `END`.
    public static func readKeyword(
        _ text: NSString,
        at offset: Int,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> (text: String, end: Int) {
        guard offset < length, startsWord(text, at: offset, length: length, grammar: grammar) else {
            return ("", offset + 1)
        }
        var cursor = offset + 1
        while cursor < length, continuesWord(text.character(at: cursor), grammar: grammar) {
            cursor += 1
        }
        let word = text.substring(with: NSRange(location: offset, length: cursor - offset))
        return (word.uppercased(), cursor)
    }

    public static func startsWord(_ text: NSString, at offset: Int, length: Int, grammar: SQLLexicalGrammar) -> Bool {
        let character = text.character(at: offset)
        if SqlDollarQuote.isIdentifierStart(character) { return true }
        guard grammar.contains(.dollarAndHashInIdentifiers), character == SqlDollarQuote.dollar, offset + 1 < length
        else { return false }
        return SqlDollarQuote.isIdentifierStart(text.character(at: offset + 1))
    }

    public static func continuesWord(_ character: UInt16, grammar: SQLLexicalGrammar) -> Bool {
        if SqlDollarQuote.isIdentifierPart(character) { return true }
        return grammar.contains(.dollarAndHashInIdentifiers)
            && (character == SqlDollarQuote.dollar || character == SqlLexer.hash)
    }

    /// What `keyword`, which ends at `wordEnd`, does to the block nesting.
    ///
    /// - Parameter allowsBlock: whether a block may open here at all. Folding passes `true`, because an anonymous
    ///   `BEGIN ... END` is foldable and folding executes nothing. Splitting passes ``opensRoutineDefinition(_:)`` for
    ///   the statement's first keyword, for the reason given on `routineDefinitionOpeners`.
    public static func effect(
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
            return endEffect(after: wordEnd, in: text, length: length)
        default:
            return .none
        }
    }

    // MARK: - Private

    private static func startsTransaction(after offset: Int, in text: NSString, length: Int) -> Bool {
        let cursor = skipTrivia(from: offset, in: text, length: length)
        guard cursor < length else { return true }
        guard text.character(at: cursor) != SqlLexer.semicolon else { return true }
        return beginStartsTransaction(followedBy: readKeyword(text, at: cursor, length: length).text)
    }

    private static func endEffect(after offset: Int, in text: NSString, length: Int) -> Effect {
        let cursor = skipTrivia(from: offset, in: text, length: length)
        guard cursor < length else { return .closesBlock(resumeAt: offset) }
        let follower = readKeyword(text, at: cursor, length: length)
        switch endingFollowedBy(follower.text) {
        case .closesControlFlow:
            return .none
        case .closesCaseStatement:
            return .closesBlock(resumeAt: follower.end)
        case .closesBlock:
            return .closesBlock(resumeAt: offset)
        }
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
