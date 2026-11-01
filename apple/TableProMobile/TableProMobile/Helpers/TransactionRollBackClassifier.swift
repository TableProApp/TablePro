import Foundation

nonisolated enum TransactionRollBackClassifier {
    private static let optionalNouns: Set<String> = ["WORK", "TRANSACTION", "TRAN"]
    // AND CHAIN and RELEASE still discard the whole transaction.
    private static let wholeTransactionTails: Set<String> = ["AND", "RELEASE"]
    // A name after ROLLBACK TRAN may be a savepoint, and TO, PREPARED or FORCE target something else.
    private static let otherTarget = "?"

    static func rollsBackTransaction(_ sql: String, statusMessage: String? = nil) -> Bool {
        // PostgreSQL answers a COMMIT in a failed transaction by rolling it back.
        if let statusMessage, statusMessage == PostgreSQLSessionTransaction.failedTransactionRolledBackMessage {
            return true
        }
        let words = leadingWords(of: sql, limit: 3)
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

    private static func leadingWords(of sql: String, limit: Int) -> [String] {
        var words: [String] = []
        var rest = Substring(sql)
        while words.count < limit {
            rest = rest.drop(while: \.isWhitespace)
            if rest.hasPrefix("--") {
                rest = rest.drop { !$0.isNewline }
            } else if rest.hasPrefix("/*") {
                // Past the opener: its `*` closes nothing, so `/*/` is still open.
                guard let end = rest.dropFirst(2).range(of: "*/") else { break }
                rest = rest[end.upperBound...]
            } else {
                let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !word.isEmpty else {
                    if let next = rest.first, next != ";" { words.append(otherTarget) }
                    break
                }
                words.append(word.uppercased())
                rest = rest.dropFirst(word.count)
            }
        }
        return words
    }
}
