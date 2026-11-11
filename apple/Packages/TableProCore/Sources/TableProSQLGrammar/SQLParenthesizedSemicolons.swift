import Foundation

// The scanner keeps the `;`s of a PostgreSQL rule's `DO ALSO (...; ...)` in its statement. A client that cuts at every
// `;` runs each piece, so a gate tiers them too: `DO ALSO (SELECT 1; DELETE FROM t)` by its `DELETE`.
enum SQLParenthesizedSemicolons {
    static func pieces(in statement: String, grammar: SQLLexicalGrammar) -> [String] {
        guard statement.utf16.contains(SqlLexer.semicolon) else { return [] }
        let text = statement as NSString
        let length = text.length
        var cuts: [Int] = []
        var depth = 0
        var index = 0
        while index < length {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                index = max(span.end, index + 1)
                continue
            }
            switch text.character(at: index) {
            case SqlLexer.openParen:
                depth += 1
            case SqlLexer.closeParen:
                depth = max(0, depth - 1)
            case SqlLexer.semicolon where depth > 0:
                cuts.append(index)
            default:
                break
            }
            index += 1
        }
        guard !cuts.isEmpty else { return [] }
        var pieces: [String] = []
        var start = 0
        for cut in cuts + [length] {
            let piece = StatementBlank.trimming(text.substring(with: NSRange(location: start, length: cut - start)))
            if !piece.isEmpty {
                pieces.append(piece)
            }
            start = cut + 1
        }
        return pieces
    }
}
