import Foundation
import TableProPluginKit

// The transaction statements a format sends around a consistent snapshot (`BEGIN`, `START TRANSACTION`, `COMMIT`).
// A source that cannot run them, because it holds rows already read or each read takes its own read-only transaction,
// passes them as no-ops.
nonisolated enum ExportSnapshotStatements {
    static let transactionKeywords: Set<String> = ["BEGIN", "START", "COMMIT", "END", "ROLLBACK"]

    static let noResult = PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)

    static func isTransactionStatement(_ statement: String) -> Bool {
        transactionKeywords.contains(leadingKeyword(of: statement))
    }

    static func leadingKeyword(of statement: String) -> String {
        var text = Substring(statement)
        while true {
            text = text.drop { $0.isWhitespace }
            if text.hasPrefix("--") {
                text = text.drop { $0 != "\n" }
            } else if text.hasPrefix("/*"), let end = text.range(of: "*/") {
                text = text[end.upperBound...]
            } else {
                break
            }
        }
        return text.prefix { $0.isLetter }.uppercased()
    }
}
