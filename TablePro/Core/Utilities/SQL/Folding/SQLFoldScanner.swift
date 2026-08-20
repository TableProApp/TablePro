//
//  SQLFoldScanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Finds the foldable regions of a SQL document in a single pass.
///
/// Statements, parenthesised groups, `BEGIN`/`CASE` blocks and multi-line block comments all open frames on one depth
/// stack, so a nested region always reports a deeper level than the region containing it. Regions that open and close
/// on the same line are discarded, because there is nothing to hide.
enum SQLFoldScanner {
    static func scan(_ text: NSString, dialect: SqlDialect) -> SQLFoldStructure {
        guard text.length > 0 else { return .empty }
        var scan = Scan(text: text, dialect: dialect)
        scan.run()
        return scan.structure
    }
}

/// One pass over a document.
///
/// The scan is a value rather than a function with captured locals, so every step of it is a named method over named
/// state instead of a closure reaching into the loop around it.
private struct Scan {
    private struct Frame {
        let kind: SQLFoldRegion.Kind
        let depth: Int
        let start: Int
        let startLine: Int
    }

    private let text: NSString
    private let length: Int
    private let dialect: SqlDialect

    private var frames: [Frame] = []
    private var completed: [SQLFoldRegion] = []
    private var index = 0
    private var line = 0

    init(text: NSString, dialect: SqlDialect) {
        self.text = text
        self.length = text.length
        self.dialect = dialect
    }

    // MARK: - Pass

    mutating func run() {
        while index < length {
            step()
        }
        closeFramesAtEndOfDocument()
    }

    private mutating func step() {
        let character = text.character(at: index)

        if consumeTrivia(character) { return }
        if consumeComment(character) { return }
        if consumeQuotedString(character) { return }
        if consumeDollarQuotedBody(character) { return }

        openStatementIfNeeded()
        consumeStructure(character)
    }

    /// Everything the pass found, indexed by the line each event lands on.
    var structure: SQLFoldStructure {
        var startsByLine: [Int: [SQLFoldRegion]] = [:]
        var endsByLine: [Int: [SQLFoldRegion]] = [:]
        for region in completed {
            startsByLine[region.startLine, default: []].append(region)
            endsByLine[region.endLine, default: []].append(region)
        }
        return SQLFoldStructure(
            startsByLine: startsByLine.mapValues { $0.sorted { $0.depth < $1.depth } },
            endsByLine: endsByLine.mapValues { $0.sorted { $0.depth > $1.depth } }
        )
    }

    // MARK: - Frames

    /// A fold starts at the end of the line that opens it, so collapsing it leaves `CREATE TABLE users (` on screen.
    private mutating func pushFrame(_ kind: SQLFoldRegion.Kind, openingToken: Int, startLine: Int) {
        frames.append(
            Frame(
                kind: kind,
                depth: frames.count + 1,
                start: SqlLexer.endOfLine(text, from: openingToken, length: length),
                startLine: startLine
            )
        )
    }

    /// Closes the innermost frame when it is the kind being closed. A `)` that does not match an open group, or an
    /// `END` with no `BEGIN`, belongs to structure this scanner does not track and is left alone.
    private mutating func popFrame(_ kind: SQLFoldRegion.Kind, end: Int) {
        guard let frame = frames.last, frame.kind == kind else { return }
        frames.removeLast()
        complete(frame, end: end, endLine: line)
    }

    private mutating func complete(_ frame: Frame, end: Int, endLine: Int) {
        guard frame.startLine != endLine else { return }
        completed.append(
            SQLFoldRegion(
                kind: frame.kind,
                depth: frame.depth,
                range: frame.start..<max(frame.start, end),
                startLine: frame.startLine,
                endLine: endLine
            )
        )
    }

    /// A document that ends mid-statement still folds what it opened, up to wherever the text stops.
    private mutating func closeFramesAtEndOfDocument() {
        for frame in frames.reversed() {
            complete(frame, end: length, endLine: line)
        }
        frames.removeAll()
    }

    /// Everything outside a `BEGIN` block or a parenthesised group belongs to a statement, which opens at the first
    /// token that is not whitespace or a comment.
    private mutating func openStatementIfNeeded() {
        guard frames.isEmpty else { return }
        pushFrame(.statement, openingToken: index, startLine: line)
    }

    // MARK: - Structure

    private mutating func consumeStructure(_ character: UInt16) {
        switch character {
        case SqlLexer.openParen:
            pushFrame(.parenGroup, openingToken: index, startLine: line)
            index += 1
        case SqlLexer.closeParen:
            popFrame(.parenGroup, end: index)
            index += 1
        case SqlLexer.semicolon:
            consumeSemicolon()
        default:
            consumeKeyword()
        }
    }

    /// A semicolon only ends the statement when the statement is the innermost open frame. Inside a `BEGIN` block or
    /// a parenthesised group it separates something nested instead.
    private mutating func consumeSemicolon() {
        if frames.last?.kind == .statement {
            popFrame(.statement, end: index)
        }
        index += 1
    }

    private mutating func consumeKeyword() {
        let word = readKeyword(from: index)
        guard !word.text.isEmpty else {
            index += 1
            return
        }

        switch word.text {
        case "BEGIN", "CASE":
            pushFrame(.keywordBlock, openingToken: word.end, startLine: line)
        case "END" where !isControlFlowEnd(after: word.end):
            popFrame(.keywordBlock, end: index)
        default:
            break
        }
        index = word.end
    }

    // MARK: - Trivia

    private mutating func consumeTrivia(_ character: UInt16) -> Bool {
        if character == SqlLexer.newline {
            line += 1
            index += 1
            return true
        }
        guard SqlLexer.isWhitespace(character) else { return false }
        index += 1
        return true
    }

    private mutating func consumeComment(_ character: UInt16) -> Bool {
        if SqlLexer.startsLineComment(text, at: index, length: length)
            || (dialect.supportsHashLineComments && character == SqlLexer.hash) {
            index = SqlLexer.endOfLine(text, from: index, length: length)
            return true
        }

        guard SqlLexer.startsBlockComment(text, at: index, length: length) else { return false }
        let start = SqlLexer.endOfLine(text, from: index, length: length)
        let startLine = line
        let span = SqlLexer.skipBlockComment(text, from: index, length: length)
        line += span.newlines
        appendSpanningRegion(.blockComment, start: start, startLine: startLine, end: span.next - 2)
        index = span.next
        return true
    }

    private mutating func consumeQuotedString(_ character: UInt16) -> Bool {
        guard SqlLexer.isQuote(character) else { return false }
        let span = SqlLexer.skipQuotedString(text, from: index, quote: character, length: length, dialect: dialect)
        line += span.newlines
        index = span.next
        return true
    }

    /// A dollar quoted body is one opaque region, so nothing inside it is read as structure. The statement around it
    /// opens first, because the body is part of that statement.
    private mutating func consumeDollarQuotedBody(_ character: UInt16) -> Bool {
        guard dialect.supportsDollarQuotes, character == SqlDollarQuote.dollar,
              case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                  at: index,
                  in: text,
                  bufLen: length
              ) else {
            return false
        }

        openStatementIfNeeded()
        let start = SqlLexer.endOfLine(text, from: index, length: length)
        let startLine = line
        let result = SqlLexer.skipDollarQuotedBody(text, from: index + openerLength, tag: tag, length: length)
        line += result.span.newlines
        appendSpanningRegion(.quotedBody, start: start, startLine: startLine, end: result.bodyEnd)
        index = result.span.next
        return true
    }

    /// Records a region that was scanned in one go rather than opened and closed on the frame stack, when it turned
    /// out to span more than one line.
    private mutating func appendSpanningRegion(
        _ kind: SQLFoldRegion.Kind,
        start: Int,
        startLine: Int,
        end: Int
    ) {
        guard startLine != line else { return }
        completed.append(
            SQLFoldRegion(
                kind: kind,
                depth: frames.count + 1,
                range: start..<max(start, end),
                startLine: startLine,
                endLine: line
            )
        )
    }

    // MARK: - Words

    private func readKeyword(from offset: Int) -> (text: String, end: Int) {
        guard SqlDollarQuote.isIdentifierStart(text.character(at: offset)) else {
            return ("", offset + 1)
        }
        var cursor = offset
        var scalars = String.UnicodeScalarView()
        while cursor < length, SqlDollarQuote.isIdentifierPart(text.character(at: cursor)) {
            if let scalar = UnicodeScalar(text.character(at: cursor)) {
                scalars.append(scalar)
            }
            cursor += 1
        }
        return (String(scalars).uppercased(), cursor)
    }

    /// `END IF`, `END LOOP`, `END WHILE` and `END FOR` close constructs this scanner does not open, so they must not
    /// pop a `BEGIN` or `CASE` frame.
    private func isControlFlowEnd(after offset: Int) -> Bool {
        var cursor = offset
        while cursor < length, SqlLexer.isWhitespace(text.character(at: cursor)) {
            cursor += 1
        }
        guard cursor < length else { return false }
        return ["IF", "LOOP", "WHILE", "FOR"].contains(readKeyword(from: cursor).text)
    }
}
