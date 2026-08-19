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
///
/// A semicolon only ends the statement when the statement is the innermost open frame: inside a `BEGIN` block or a
/// parenthesised group it separates something nested instead.
enum SQLFoldScanner {
    private struct Frame {
        let kind: SQLFoldRegion.Kind
        let depth: Int
        let start: Int
        let startLine: Int
    }

    static func scan(_ text: NSString, dialect: SqlDialect) -> SQLFoldStructure {
        let length = text.length
        guard length > 0 else { return .empty }

        var completed: [SQLFoldRegion] = []
        var frames: [Frame] = []
        var line = 0
        var index = 0

        func pushFrame(_ kind: SQLFoldRegion.Kind, openingToken: Int, startLine: Int) {
            let start = SqlLexer.endOfLine(text, from: openingToken, length: length)
            frames.append(Frame(kind: kind, depth: frames.count + 1, start: start, startLine: startLine))
        }

        func popFrame(_ kind: SQLFoldRegion.Kind, end: Int, endLine: Int) {
            guard let frame = frames.last, frame.kind == kind else { return }
            frames.removeLast()
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

        while index < length {
            let char = text.character(at: index)

            if char == SqlLexer.newline {
                line += 1
                index += 1
                continue
            }

            if SqlLexer.isWhitespace(char) {
                index += 1
                continue
            }

            if SqlLexer.startsLineComment(text, at: index, length: length) {
                index = SqlLexer.endOfLine(text, from: index, length: length)
                continue
            }

            if dialect.supportsHashLineComments, char == SqlLexer.hash {
                index = SqlLexer.endOfLine(text, from: index, length: length)
                continue
            }

            if SqlLexer.startsBlockComment(text, at: index, length: length) {
                let scanned = scanBlockComment(text, from: index, length: length, depth: frames.count + 1, line: &line)
                completed.append(contentsOf: scanned.region.map { [$0] } ?? [])
                index = scanned.next
                continue
            }

            if SqlLexer.isQuote(char) {
                let span = SqlLexer.skipQuotedString(
                    text,
                    from: index,
                    quote: char,
                    length: length,
                    dialect: dialect
                )
                line += span.newlines
                index = span.next
                continue
            }

            if dialect.supportsDollarQuotes, char == SqlDollarQuote.dollar,
               case .opener(let openerLength, let tag) = SqlDollarQuote.scanOpener(
                   at: index,
                   in: text,
                   bufLen: length
               ) {
                if frames.isEmpty {
                    pushFrame(.statement, openingToken: index, startLine: line)
                }
                let scanned = scanDollarQuote(
                    text,
                    from: index,
                    openerLength: openerLength,
                    tag: tag,
                    length: length,
                    depth: frames.count + 1,
                    line: &line
                )
                completed.append(contentsOf: scanned.region.map { [$0] } ?? [])
                index = scanned.next
                continue
            }

            if frames.isEmpty {
                pushFrame(.statement, openingToken: index, startLine: line)
            }

            if char == SqlLexer.openParen {
                pushFrame(.parenGroup, openingToken: index, startLine: line)
                index += 1
                continue
            }

            if char == SqlLexer.closeParen {
                popFrame(.parenGroup, end: index, endLine: line)
                index += 1
                continue
            }

            if char == SqlLexer.semicolon {
                if frames.last?.kind == .statement {
                    popFrame(.statement, end: index, endLine: line)
                }
                index += 1
                continue
            }

            let word = readKeyword(text, from: index, length: length)
            guard !word.text.isEmpty else {
                index += 1
                continue
            }

            switch word.text {
            case "BEGIN", "CASE":
                pushFrame(.keywordBlock, openingToken: word.end, startLine: line)
            case "END":
                if isControlFlowEnd(text, after: word.end, length: length) {
                    break
                }
                popFrame(.keywordBlock, end: index, endLine: line)
            default:
                break
            }
            index = word.end
        }

        let documentEnd = length
        for frame in frames.reversed() where frame.startLine != line {
            completed.append(
                SQLFoldRegion(
                    kind: frame.kind,
                    depth: frame.depth,
                    range: frame.start..<max(frame.start, documentEnd),
                    startLine: frame.startLine,
                    endLine: line
                )
            )
        }

        return makeStructure(completed)
    }

    // MARK: - Frame helpers

    private static func makeStructure(_ regions: [SQLFoldRegion]) -> SQLFoldStructure {
        var startsByLine: [Int: [SQLFoldRegion]] = [:]
        var endsByLine: [Int: [SQLFoldRegion]] = [:]
        for region in regions {
            startsByLine[region.startLine, default: []].append(region)
            endsByLine[region.endLine, default: []].append(region)
        }
        return SQLFoldStructure(
            startsByLine: startsByLine.mapValues { $0.sorted { $0.depth < $1.depth } },
            endsByLine: endsByLine.mapValues { $0.sorted { $0.depth > $1.depth } }
        )
    }

    // MARK: - Scanning helpers

    /// Consumes a block comment, reporting it as a fold when it spans more than one line.
    private static func scanBlockComment(
        _ text: NSString,
        from offset: Int,
        length: Int,
        depth: Int,
        line: inout Int
    ) -> (region: SQLFoldRegion?, next: Int) {
        let start = SqlLexer.endOfLine(text, from: offset, length: length)
        let startLine = line
        let span = SqlLexer.skipBlockComment(text, from: offset, length: length)
        line += span.newlines
        guard startLine != line else { return (nil, span.next) }
        return (
            SQLFoldRegion(
                kind: .blockComment,
                depth: depth,
                range: start..<max(start, span.next - 2),
                startLine: startLine,
                endLine: line
            ),
            span.next
        )
    }

    /// Consumes a dollar quoted body as one opaque region, so nothing inside it is treated as structure.
    private static func scanDollarQuote(
        _ text: NSString,
        from offset: Int,
        openerLength: Int,
        tag: String,
        length: Int,
        depth: Int,
        line: inout Int
    ) -> (region: SQLFoldRegion?, next: Int) {
        let start = SqlLexer.endOfLine(text, from: offset, length: length)
        let startLine = line
        let result = SqlLexer.skipDollarQuotedBody(text, from: offset + openerLength, tag: tag, length: length)
        line += result.span.newlines
        guard startLine != line else { return (nil, result.span.next) }
        return (
            SQLFoldRegion(
                kind: .quotedBody,
                depth: depth,
                range: start..<max(start, result.bodyEnd),
                startLine: startLine,
                endLine: line
            ),
            result.span.next
        )
    }

    private static func readKeyword(_ text: NSString, from offset: Int, length: Int) -> (text: String, end: Int) {
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
    private static func isControlFlowEnd(_ text: NSString, after offset: Int, length: Int) -> Bool {
        var cursor = offset
        while cursor < length, SqlLexer.isWhitespace(text.character(at: cursor)) {
            cursor += 1
        }
        guard cursor < length else { return false }
        let next = readKeyword(text, from: cursor, length: length)
        return ["IF", "LOOP", "WHILE", "FOR"].contains(next.text)
    }
}
