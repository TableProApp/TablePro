import Foundation

/// The lines of a psql script that are not SQL, read the way psql 17 and 18 read them.
///
/// `COPY ... FROM STDIN` takes its rows from the script itself: the lines after the line its `;` ends on, up to a line
/// holding only `\.`, or to the end of the script. psql skips them even when the `COPY` fails, since a row run as SQL
/// can be any statement. pg_dump writes a script that opens with `\restrict <key>` and closes with `\unrestrict <key>`,
/// which only limit psql's own meta-commands; nothing here runs one, so both lines run nothing.
public enum SQLPsqlScript {
    private static let backslash = SqlLexer.backslash
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let restrict = Array("restrict".utf16)
    private static let unrestrict = Array("unrestrict".utf16)

    /// Everything after the `;` at `semicolon` that belongs to a `COPY ... FROM STDIN`: the rest of the `;`'s line, then
    /// each line up to and including the one holding only `\.`, its line break excluded, or up to the end of the text.
    ///
    /// psql runs code after the `;` on its own line once the rows are in. pg_dump never writes any, and here it never
    /// runs, so a line break after it cannot decide whether it does.
    public static func copyRows(afterSemicolonAt semicolon: Int, in text: NSString, length: Int) -> NSRange {
        guard var lineStart = lineEnd(in: text, from: semicolon + 1, length: length).map({ $0 + 1 }) else {
            return NSRange(location: semicolon + 1, length: length - semicolon - 1)
        }
        while lineStart < length {
            if let markerEnd = endOfDataMarker(in: text, at: lineStart, length: length) {
                return NSRange(location: semicolon + 1, length: markerEnd - semicolon - 1)
            }
            guard let next = lineEnd(in: text, from: lineStart, length: length) else { break }
            lineStart = next + 1
        }
        return NSRange(location: semicolon + 1, length: length - semicolon - 1)
    }

    /// The `\restrict` or `\unrestrict` line whose backslash is at `offset`, its line break excluded, when only blanks
    /// stand before it on its line. psql reads both names case for case.
    public static func restrictLine(at offset: Int, in text: NSString, length: Int) -> NSRange? {
        var before = offset - 1
        while before >= 0, isLineBlank(text.character(at: before)) {
            before -= 1
        }
        guard before < 0 || text.character(at: before) == SqlLexer.newline,
              let nameEnd = restrictNameEnd(in: text, at: offset, length: length)
        else {
            return nil
        }
        let end = lineEnd(in: text, from: nameEnd, length: length) ?? length
        return NSRange(location: offset, length: end - offset)
    }

    /// Whether a `\restrict` or `\unrestrict` line starts at `offset`, for a reader that already knows only blanks
    /// stand before it on its line. `text` has to hold the unit after the name unless the name ends the text.
    public static func startsRestrictLine(in text: NSString, at offset: Int, length: Int) -> Bool {
        restrictNameEnd(in: text, at: offset, length: length) != nil
    }

    /// How many units a reader needs from a backslash on to answer ``startsRestrictLine(in:at:length:)``.
    public static let restrictLineLookahead = 1 + 10 + 1

    private static func restrictNameEnd(in text: NSString, at offset: Int, length: Int) -> Int? {
        guard offset < length, text.character(at: offset) == backslash,
              let nameEnd = [restrict, unrestrict].lazy.compactMap({ name in
                  matches(name, in: text, at: offset + 1, length: length) ? offset + 1 + name.count : nil
              }).first
        else {
            return nil
        }
        if nameEnd < length {
            let next = text.character(at: nameEnd)
            guard isLineBlank(next) || next == SqlLexer.newline || next == SqlLexer.carriageReturn else { return nil }
        }
        return nameEnd
    }

    // psql 18 matches `\.` + LF or CRLF at a line's start only; a last line `\.` with no line break ends the rows too.
    // The unit after the returned end, when there is one, was read to decide.
    private static func endOfDataMarker(in text: NSString, at lineStart: Int, length: Int) -> Int? {
        guard lineStart + 1 < length,
              text.character(at: lineStart) == backslash,
              text.character(at: lineStart + 1) == period
        else {
            return nil
        }
        let after = lineStart + 2
        guard after < length else { return after }
        switch text.character(at: after) {
        case SqlLexer.newline:
            return after
        case SqlLexer.carriageReturn where after + 1 == length || text.character(at: after + 1) == SqlLexer.newline:
            return after
        default:
            return nil
        }
    }

    private static func lineEnd(in text: NSString, from offset: Int, length: Int) -> Int? {
        guard offset < length else { return nil }
        let found = text.range(
            of: "\n",
            options: .literal,
            range: NSRange(location: offset, length: length - offset)
        )
        return found.location == NSNotFound ? nil : found.location
    }

    private static func matches(_ name: [UInt16], in text: NSString, at offset: Int, length: Int) -> Bool {
        guard offset + name.count <= length else { return false }
        for (index, unit) in name.enumerated() where text.character(at: offset + index) != unit {
            return false
        }
        return true
    }

    private static func isLineBlank(_ unit: UInt16) -> Bool {
        unit == SqlLexer.space || unit == SqlLexer.tab
    }
}

/// psql's test for a statement that takes rows from the script: its first word is `COPY`, and among its first eight
/// words outside parentheses a `FROM` comes right before `STDIN` or `STDOUT`, which the server's grammar does not tell
/// apart. A quoted name is no word, and a dotted name is one word per part.
struct SQLCopyFromStandardInput {
    private static let wordsRead = 8

    private var words = 0
    private var parenDepth = 0
    private var followsFrom = false
    private var settled = false
    private(set) var readsRows = false

    var needsWords: Bool {
        !settled
    }

    mutating func observeWord(_ word: String) {
        guard !settled, parenDepth == 0 else { return }
        if words == 0, word != "COPY" {
            settled = true
            return
        }
        if followsFrom, word == "STDIN" || word == "STDOUT" {
            readsRows = true
            settled = true
            return
        }
        followsFrom = word == "FROM"
        words += 1
        if words == Self.wordsRead {
            settled = true
        }
    }

    mutating func observeSymbol(_ symbol: UInt16) {
        guard !settled else { return }
        switch symbol {
        case SqlLexer.openParen:
            parenDepth += 1
        case SqlLexer.closeParen:
            parenDepth = max(0, parenDepth - 1)
        default:
            break
        }
        if words == 0 {
            settled = true
        }
    }

    mutating func observeOpaqueToken() {
        if words == 0 {
            settled = true
        }
    }
}

/// A statement tracker that also tells a `COPY ... FROM STDIN`, for a grammar with ``SQLLexicalGrammar/psqlScripts``.
struct SQLPsqlStatementTracker: SQLStatementBoundaryTracking {
    private var base: any SQLStatementBoundaryTracking
    private var copy = SQLCopyFromStandardInput()

    init(base: any SQLStatementBoundaryTracking) {
        self.base = base
    }

    var needsWords: Bool {
        base.needsWords || copy.needsWords
    }

    var terminator: SQLStatementTerminator {
        base.terminator
    }

    var acceptsBindParameters: Bool {
        base.acceptsBindParameters
    }

    var holdsOpenBlock: Bool {
        base.holdsOpenBlock
    }

    var awaitsContinuation: Bool {
        base.awaitsContinuation
    }

    var copiesFromStandardInput: Bool {
        copy.readsRows
    }

    mutating func observeWord(_ word: String) {
        copy.observeWord(word)
        if base.needsWords {
            base.observeWord(word)
        }
    }

    mutating func observeSymbol(_ symbol: UInt16) {
        copy.observeSymbol(symbol)
        base.observeSymbol(symbol)
    }

    mutating func observeOpaqueToken() {
        copy.observeOpaqueToken()
        base.observeOpaqueToken()
    }

    mutating func observeQuotedToken(opener: UInt16) {
        copy.observeOpaqueToken()
        base.observeQuotedToken(opener: opener)
    }

    mutating func observeGap() {
        base.observeGap()
    }

    mutating func observeSemicolon() -> Bool {
        base.observeSemicolon()
    }

    mutating func continuesStatement(with word: String?) -> Bool {
        base.continuesStatement(with: word)
    }

    mutating func reset() {
        base.reset()
        copy = SQLCopyFromStandardInput()
    }
}
