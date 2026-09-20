import Foundation

/// SQL text with every comment, literal and quoted identifier blanked, read by one grammar.
///
/// A classifier looks for keywords in what this returns, so a `DROP` inside a string never counts and a `DROP` after
/// a string that ended where the engine ends it always does. Each blanked UTF-16 unit becomes a space and each line
/// feed stays, so an offset into the projection is an offset into the original text.
public enum SQLCodeProjection {
    /// - Parameter revealingExecutableComments: whether a MySQL `/*! ... */` body is kept as code. A gate reveals it
    ///   whatever the grammar says, because the only cost of reading an ignored comment as code is a stricter tier.
    public static func code(
        of text: String,
        grammar: SQLLexicalGrammar,
        revealingExecutableComments: Bool = false
    ) -> String {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return "" }
        var units = [UInt16](repeating: 0, count: length)
        source.getCharacters(&units, range: NSRange(location: 0, length: length))

        var index = 0
        while index < length {
            if revealingExecutableComments,
               let opener = SqlLexer.executableCommentOpenerLength(source, at: index, length: length) {
                index += opener
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) else {
                index += 1
                continue
            }
            blank(&units, from: span.start, to: span.end)
            index = max(span.end, index + 1)
        }
        return String(utf16CodeUnits: units, count: length)
    }

    private static func blank(_ units: inout [UInt16], from start: Int, to end: Int) {
        for offset in start..<min(end, units.count) where units[offset] != SqlLexer.newline {
            units[offset] = SqlLexer.space
        }
    }
}
