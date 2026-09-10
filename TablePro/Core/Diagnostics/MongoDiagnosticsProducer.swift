import Foundation
import TableProPluginKit

/// Underlines what MongoDB will refuse to run.
///
/// The query language is JavaScript, so the check is a JavaScript parse rather than a match against
/// a list of method names. Checking against a list said `forEach` was an unsupported method and
/// underlined every script that iterated a cursor, while saying nothing about a missing brace.
struct MongoDiagnosticsProducer: QueryDiagnosticsProducing {
    private static let maximumLength = 100_000

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        let source = text as NSString
        guard source.length > 0, source.length <= Self.maximumLength else { return [] }

        // The bracket scanner has no regex state, so `db.c.find({x:/[)]/})` reads as an unmatched
        // closer. The syntax checker below knows JavaScript properly, so the structural pass is
        // only there to stay quiet while a query is still being typed.
        let structure = QueryBracketScanner.scan(source, comments: .javaScript)
        let hasRegexLiteral = source.range(of: "/", options: .literal).location != NSNotFound

        if let range = structure.unmatchedClose, !hasRegexLiteral {
            return [QueryDiagnostic(range: range, message: String(localized: "No matching opening bracket"))]
        }
        if let range = structure.unterminatedComment {
            return [QueryDiagnostic(range: range, message: String(localized: "Unterminated comment"))]
        }

        guard !structure.hasUnterminatedString else { return [] }
        guard !structure.hasUnclosedOpener || hasRegexLiteral else { return [] }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        guard let failure = JavaScriptSyntaxChecker.firstFailure(in: blankingShellCommands(source)) else {
            return []
        }
        return [QueryDiagnostic(range: range(ofLine: failure.line, in: source), message: failure.message)]
    }

    /// The document with every `use orders` and `show collections` line blanked out.
    ///
    /// Blanked rather than rewritten, and with its newlines kept, so the parser never sees shell
    /// syntax and a syntax error it does report still lands on the line the reader typed.
    private func blankingShellCommands(_ source: NSString) -> String {
        let statements = JavaScriptStatementScanner.executableStatements(in: source as String)
        var checked = source as String
        for statement in statements.reversed() where MongoShellCommandRecognizer.isShellCommand(statement.trimmed) {
            let blank = statement.text.map { $0.isNewline ? $0 : " " }
            checked = (checked as NSString).replacingCharacters(
                in: statement.range, with: String(blank)
            )
        }
        return checked
    }

    private func range(ofLine line: Int, in source: NSString) -> NSRange {
        var current = 1
        var location = 0
        while current < line, location < source.length {
            location = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard location < source.length else {
            return NSRange(location: max(0, source.length - 1), length: min(1, source.length))
        }
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let trimmedLength = source.substring(with: lineRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .utf16
            .count
        guard trimmedLength > 0 else { return lineRange }
        return NSRange(location: lineRange.location, length: min(trimmedLength, source.length - lineRange.location))
    }
}
