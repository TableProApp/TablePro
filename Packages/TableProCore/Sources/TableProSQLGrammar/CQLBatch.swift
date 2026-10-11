import Foundation

/// The words that open and close a CQL batch, and the statements one runs.
///
/// ``CQLBatchTracker`` keeps a batch whole for the driver, folding closes its block at `APPLY BATCH`, and a gate tiers
/// it by the statements ``statements(in:grammar:)`` finds inside it. All three read the words from here, so they agree
/// on where a batch starts and where it stops.
public enum CQLBatch {
    static let opener = "BEGIN"
    static let kinds: Set<String> = ["UNLOGGED", "COUNTER"]
    static let keyword = "BATCH"
    static let closer = "APPLY"

    /// The words of the `USING` clause a batch may open with. Its values are numbers and bind markers, never words,
    /// except the name after a `:`.
    private static let usingClauseWords: Set<String> = ["USING", "TIMESTAMP", "TTL", "AND"]
    private static let colon = UInt16(UnicodeScalar(":").value)

    /// The statements `statement` runs when it is a batch, each as the driver would receive it alone, or nil when it
    /// is not one. A batch that never reaches `APPLY BATCH` runs to the end of the text, which is how it is sent.
    public static func statements(in statement: String, grammar: SQLLexicalGrammar) -> [String]? {
        guard grammar.contains(.cqlBatches) else { return nil }
        let code = SQLCodeProjection.code(of: statement, grammar: grammar) as NSString
        guard let body = body(in: code, grammar: grammar) else { return nil }
        let inner = (statement as NSString).substring(with: body)
        return SQLStatementScanner.executableStatements(in: inner, grammar: grammar.subtracting(.cqlBatches))
            .map(\.sql)
    }

    // MARK: - Private

    private struct Token {
        let word: String?
        let unit: UInt16
        let start: Int
    }

    /// The words and single symbols of a code projection, in which every literal and comment is already blank.
    private struct Tokens {
        let code: NSString
        let grammar: SQLLexicalGrammar
        var cursor = 0

        mutating func next() -> Token? {
            let length = code.length
            while cursor < length, SqlLexer.isWhitespace(code.character(at: cursor)) {
                cursor += 1
            }
            guard cursor < length else { return nil }
            let start = cursor
            let word = SqlBlockStructure.readKeyword(code, at: start, length: length, grammar: grammar)
            cursor = word.end
            return Token(word: word.text.isEmpty ? nil : word.text, unit: code.character(at: start), start: start)
        }
    }

    /// The span between the batch's header and its `APPLY BATCH`, or nil when the code opens no batch.
    private static func body(in code: NSString, grammar: SQLLexicalGrammar) -> NSRange? {
        var tokens = Tokens(code: code, grammar: grammar)
        guard tokens.next()?.word == opener else { return nil }
        var token = tokens.next()
        if let kind = token?.word, kinds.contains(kind) {
            token = tokens.next()
        }
        guard token?.word == keyword else { return nil }
        guard let first = firstStatementWord(in: &tokens) else {
            return NSRange(location: code.length, length: 0)
        }
        let end = closerStart(in: &tokens, from: first) ?? code.length
        return NSRange(location: first.start, length: end - first.start)
    }

    private static func firstStatementWord(in tokens: inout Tokens) -> Token? {
        var followsColon = false
        while let token = tokens.next() {
            guard let word = token.word else {
                followsColon = token.unit == colon
                continue
            }
            guard followsColon || usingClauseWords.contains(word) else { return token }
            followsColon = false
        }
        return nil
    }

    private static func closerStart(in tokens: inout Tokens, from first: Token) -> Int? {
        var current: Token? = first
        var pendingCloser: Token?
        while let token = current {
            if let pendingCloser, token.word == keyword {
                return pendingCloser.start
            }
            pendingCloser = token.word == closer ? token : nil
            current = tokens.next()
        }
        return nil
    }
}
