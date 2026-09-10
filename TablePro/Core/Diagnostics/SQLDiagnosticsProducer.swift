import Foundation

/// Reports only structural problems more typing cannot fix. TablePro has no SQL grammar, and a
/// half-written statement must never be flagged, so an unclosed bracket is deliberately silent.
struct SQLDiagnosticsProducer: QueryDiagnosticsProducing {
    private static let maximumLength = 100_000

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= Self.maximumLength else { return [] }

        let structure = QueryBracketScanner.scan(source, comments: .sql)
        var results: [QueryDiagnostic] = []

        if let range = structure.unmatchedClose {
            results.append(QueryDiagnostic(range: range, message: String(localized: "No matching opening bracket")))
        }
        if let range = structure.unterminatedComment {
            results.append(QueryDiagnostic(range: range, message: String(localized: "Unterminated comment")))
        }

        return results
    }
}
