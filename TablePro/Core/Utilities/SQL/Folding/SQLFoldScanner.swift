//
//  SQLFoldScanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

/// Finds the foldable regions of a SQL document in a single pass.
///
/// Statements, parenthesised groups, `BEGIN`/`CASE` blocks and multi-line block comments all open frames on one depth
/// stack, so a nested region always reports a deeper level than the region containing it. Regions that open and close
/// on the same line are discarded, because there is nothing to hide.
enum SQLFoldScanner {
    static func scan(_ text: NSString, grammar: SQLLexicalGrammar) -> SQLFoldStructure {
        guard text.length > 0 else { return .empty }
        var scan = Scan(text: text, grammar: grammar)
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
    private let grammar: SQLLexicalGrammar

    private var frames: [Frame] = []
    private var completed: [SQLFoldRegion] = []
    private var index = 0
    private var line = 0

    /// The statement scanner's own grammar, asked whether a `;` ends the statement so the fold and the run control
    /// in the same gutter agree about where a statement stops.
    private var boundaries: any SQLStatementBoundaryTracking

    init(text: NSString, grammar: SQLLexicalGrammar) {
        self.text = text
        self.length = text.length
        self.grammar = grammar
        self.boundaries = SQLStatementBoundaries.makeTracker(for: grammar)
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
        if consumeNonCode() { return }
        if consumeSlashLine(character) { return }

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
        popFrame(kind, end: end, endLine: line)
    }

    private mutating func popFrame(_ kind: SQLFoldRegion.Kind, end: Int, endLine: Int) {
        guard let frame = frames.last, frame.kind == kind else { return }
        frames.removeLast()
        complete(frame, end: end, endLine: endLine)
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
            boundaries.observeSymbol(character)
            pushFrame(.parenGroup, openingToken: index, startLine: line)
            index += 1
        case SqlLexer.closeParen:
            boundaries.observeSymbol(character)
            popFrame(.parenGroup, end: index)
            index += 1
        case SqlLexer.semicolon:
            consumeSemicolon()
        default:
            consumeKeyword(character)
        }
    }

    /// A semicolon only ends the statement when the statement grammar says it does and the statement is the innermost
    /// open frame. Inside a `BEGIN` block or a parenthesised group it separates something nested instead.
    ///
    /// Oracle's grammar is authoritative in both directions, because a PL/SQL unit's `IS` and `AS` bodies open no fold
    /// frame of their own: when it ends the unit, whatever the fold still holds open ends with it.
    private mutating func consumeSemicolon() {
        let endsStatement = boundaries.observeSemicolon()
        if endsStatement {
            boundaries.reset()
            if grammar.contains(.plsqlBlocks) {
                closeFramesThroughStatement(end: index)
            }
        }
        if endsStatement, frames.last?.kind == .statement {
            popFrame(.statement, end: index)
        }
        index += 1
    }

    private mutating func closeFramesThroughStatement(end: Int, endLine: Int? = nil) {
        guard frames.contains(where: { $0.kind == .statement }) else { return }
        while let frame = frames.last, frame.kind != .statement {
            frames.removeLast()
            complete(frame, end: end, endLine: endLine ?? line)
        }
    }

    private mutating func consumeKeyword(_ character: UInt16) {
        let word = SqlBlockStructure.readKeyword(text, at: index, length: length, grammar: grammar)
        guard !word.text.isEmpty else {
            if !SqlLexer.isWhitespace(character) {
                boundaries.observeSymbol(character)
            }
            index += 1
            return
        }

        boundaries.observeWord(word.text)
        switch SqlBlockStructure.effect(
            of: word.text,
            endingAt: word.end,
            in: text,
            length: length,
            allowsBlock: true,
            grammar: grammar
        ) {
        case .opensBlock:
            pushFrame(.keywordBlock, openingToken: word.end, startLine: line)
            index = word.end
        case let .closesBlock(resumeAt):
            popFrame(.keywordBlock, end: index)
            index = max(word.end, resumeAt)
        case .none:
            index = word.end
        }
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

    /// A comment, a literal or a quoted identifier, ended where the grammar ends it. A block comment and a dollar
    /// quoted body that span lines fold; nothing inside either is read as structure.
    private mutating func consumeNonCode() -> Bool {
        guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) else { return false }
        let start = SqlLexer.endOfLine(text, from: index, length: length)
        let startLine = line
        switch span.kind {
        case .lineComment:
            break
        case .blockComment, .executableComment:
            line += span.newlines
            appendSpanningRegion(.blockComment, start: start, startLine: startLine, end: span.contentEnd)
        case .quoted where text.character(at: index) == SqlDollarQuote.dollar:
            openStatementIfNeeded()
            boundaries.observeOpaqueToken()
            line += span.newlines
            appendSpanningRegion(.quotedBody, start: start, startLine: startLine, end: span.contentEnd)
        case .quoted, .parameter:
            boundaries.observeOpaqueToken()
            line += span.newlines
        }
        index = max(span.end, index + 1)
        return true
    }

    /// A `/` alone on its line ends whatever statement is open, as SQL*Plus reads it. The statement ends where its own
    /// text does, on a line above the slash, so a one-line statement stays unfoldable.
    private mutating func consumeSlashLine(_ character: UInt16) -> Bool {
        guard grammar.contains(.slashLineTerminators), character == SqlLexer.slash,
              SQLStatementScanner.isSlashLine(text, at: index, length: length)
        else {
            return false
        }
        var end = index
        var endLine = line
        while end > 0, SqlLexer.isWhitespace(text.character(at: end - 1)) {
            end -= 1
            if text.character(at: end) == SqlLexer.newline {
                endLine -= 1
            }
        }
        closeFramesThroughStatement(end: end, endLine: endLine)
        if frames.last?.kind == .statement {
            popFrame(.statement, end: end, endLine: endLine)
        }
        boundaries.reset()
        index += 1
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
}
