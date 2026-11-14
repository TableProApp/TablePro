import Foundation
import TableProSQLGrammar

nonisolated enum TransactionRollBackClassifier {
    private static let optionalNouns: Set<String> = ["WORK", "TRANSACTION", "TRAN"]
    // AND CHAIN and RELEASE still discard the whole transaction.
    private static let wholeTransactionTails: Set<String> = ["AND", "RELEASE"]
    // A name after ROLLBACK TRAN may be a savepoint, and TO, PREPARED or FORCE target something else.
    private static let otherTarget = "?"

    static func rollsBackTransaction(_ sql: String, grammar: SQLLexicalGrammar, statusMessage: String? = nil) -> Bool {
        // PostgreSQL answers a COMMIT in a failed transaction by rolling it back.
        if let statusMessage, statusMessage == PostgreSQLSessionTransaction.failedTransactionRolledBackMessage {
            return true
        }
        let words = leadingWords(of: sql, limit: 3, grammar: grammar)
        switch words.first ?? "" {
        case "ABORT":
            return true
        case "ROLLBACK":
            var rest = words.dropFirst()
            if let noun = rest.first, optionalNouns.contains(noun) {
                rest = rest.dropFirst()
            }
            guard let next = rest.first else { return true }
            return wholeTransactionTails.contains(next)
        default:
            return false
        }
    }

    // Comments end where the engine ends them: a MySQL `#` line, a nested PostgreSQL `/* */`.
    private static func leadingWords(of sql: String, limit: Int, grammar: SQLLexicalGrammar) -> [String] {
        let text = sql as NSString
        var words: [String] = []
        var index = 0
        while words.count < limit, index < text.length {
            let unit = text.character(at: index)
            if UnicodeScalar(unit).map(CharacterSet.whitespacesAndNewlines.contains) == true {
                index += 1
                continue
            }
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                guard span.kind.isComment else {
                    words.append(otherTarget)
                    break
                }
                index = max(span.end, index + 1)
                continue
            }
            var end = index
            while end < text.length, SQLNonCodeSpan.isWordUnit(text.character(at: end)) {
                end += 1
            }
            guard end > index else {
                if unit != SqlLexer.semicolon { words.append(otherTarget) }
                break
            }
            words.append(text.substring(with: NSRange(location: index, length: end - index)).uppercased())
            index = end
        }
        return words
    }
}
