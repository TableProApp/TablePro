import Foundation

nonisolated enum TransactionRollBackClassifier {
    private static let optionalNouns: Set<String> = ["WORK", "TRANSACTION", "TRAN"]
    // ROLLBACK TO keeps the transaction open; ROLLBACK PREPARED and ROLLBACK FORCE end a different one.
    private static let partialTargets: Set<String> = ["TO", "PREPARED", "FORCE"]

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
            return !partialTargets.contains(next)
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
                guard let end = rest.range(of: "*/") else { break }
                rest = rest[end.upperBound...]
            } else {
                let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                guard !word.isEmpty else { break }
                words.append(word.uppercased())
                rest = rest.dropFirst(word.count)
            }
        }
        return words
    }
}
