import Foundation
import TableProSQLGrammar

// Read from the caret's statement start, so a cut never lands inside a comment or literal.
public enum SQLCompletionWindow {
    public static let radius = 5_000

    // The statement scan is linear in the document, so an editor runs it off the main actor.
    @concurrent
    public static func cut(
        _ text: String,
        around offset: Int,
        grammar: SQLLexicalGrammar
    ) async -> (text: String, start: Int)? {
        cut(text as NSString, around: offset, grammar: grammar)
    }

    // Nil when the caret sits in a comment or literal that opens before the cut, where nothing completes.
    public static func cut(
        _ text: NSString,
        around offset: Int,
        grammar: SQLLexicalGrammar
    ) -> (text: String, start: Int)? {
        let length = text.length
        let caret = min(max(offset, 0), length)
        // A bridged Swift string translates every UTF-16 offset it is asked for, so the scan reads one UTF-16 copy.
        var units = [UInt16](repeating: 0, count: length)
        text.getCharacters(&units, range: NSRange(location: 0, length: length))
        let source = units.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { NSString(characters: $0, length: length) } ?? NSString()
        }

        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: source as String, cursorPosition: caret, grammar: grammar
        )
        let end = max(caret, min(NSMaxRange(located.range), caret + radius))
        var start = min(located.offset, caret)
        if caret - start > radius {
            guard let resumed = codeStart(in: source, units: units, from: start, around: caret, grammar: grammar) else {
                return nil
            }
            start = resumed
        }
        return (source.substring(with: NSRange(location: start, length: end - start)), start)
    }

    // A start glued to the word before it is passed over: `E'` and `$$` read differently with nothing in front.
    private static func codeStart(
        in text: NSString,
        units: [UInt16],
        from statementStart: Int,
        around caret: Int,
        grammar: SQLLexicalGrammar
    ) -> Int? {
        let target = caret - radius
        var index = statementStart
        var firstCodePosition: Int?
        while index < caret {
            if index >= target {
                if firstCodePosition == nil { firstCodePosition = index }
                if !SqlDollarQuote.isIdentifierContinuation(units[index - 1]) { return index }
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar),
                  span.kind != .executableComment else {
                index += 1
                continue
            }
            if SQLContextAnalyzer.holds(span, cursor: caret) {
                return SQLContextAnalyzer.isQuotedIdentifier(span, in: text, grammar: grammar) ? span.start : nil
            }
            index = max(span.end, index + 1)
        }
        return firstCodePosition ?? caret
    }
}
