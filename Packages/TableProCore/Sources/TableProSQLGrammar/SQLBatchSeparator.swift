import Foundation

/// A line holding only `GO`, which ends a batch the way sqlcmd and SQL Server Management Studio read a script.
///
/// `GO` is the client's word, not the server's: sent to SQL Server it is a syntax error, so the line belongs to no
/// statement and is never sent. What it does is decide which statements reach the server together, and T-SQL scopes a
/// local variable, a table variable and a `TRY...CATCH` to the batch that holds them.
///
/// The rules are sqlcmd's as sqltoolsservice implements them. The line starts with `GO` after nothing but spaces and
/// tabs, may add a positive repeat count that fits in 32 bits and a `--` comment, and holds nothing else: `GO;`,
/// `GO 0` and `SELECT 1 GO` are not separators, and reach the server as the text they are. Only code is read, so a
/// `GO` line inside a string, a quoted identifier or a block comment, however many lines those span, separates
/// nothing.
public struct SQLBatchSeparator: Sendable, Equatable {
    /// The line from its `GO` to the end of the line, the line break excluded.
    public let range: NSRange

    /// How many times the batch before the line runs: `GO 5` runs it five times.
    public let repeatCount: Int

    public init(range: NSRange, repeatCount: Int) {
        self.range = range
        self.repeatCount = repeatCount
    }

    private static let capitalG = UInt16(UnicodeScalar("G").value)
    private static let smallG = UInt16(UnicodeScalar("g").value)
    private static let capitalO = UInt16(UnicodeScalar("O").value)
    private static let smallO = UInt16(UnicodeScalar("o").value)
    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)

    /// The separator whose `GO` starts at `offset`, or nil when the line there is not one.
    ///
    /// `offset` has to be code: the caller has already stepped over every comment and literal before it, which is
    /// what keeps a `GO` inside one from counting.
    static func line(
        at offset: Int,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> SQLBatchSeparator? {
        guard startsLine(text, at: offset) else { return nil }
        return line(startingAt: offset, in: text, length: length, grammar: grammar)
    }

    /// The separator whose `GO` starts at `offset`, for a reader that has already seen that nothing but spaces and
    /// tabs stand before it on its line, such as one reading a file a chunk at a time whose buffer no longer holds
    /// the start of the line.
    ///
    /// `text` has to hold the whole line, its line break included, unless the line ends the text: the rest of the
    /// line is what decides, and a line cut short at `length` reads as ending there.
    public static func line(
        startingAt offset: Int,
        in text: NSString,
        length: Int,
        grammar: SQLLexicalGrammar
    ) -> SQLBatchSeparator? {
        guard offset + 1 < length,
              isG(text.character(at: offset)),
              isO(text.character(at: offset + 1))
        else {
            return nil
        }
        var cursor = offset + 2
        if cursor < length, SqlBlockStructure.continuesWord(text.character(at: cursor), grammar: grammar) {
            return nil
        }
        cursor = skippingLineBlanks(text, from: cursor, length: length)

        var repeatCount = 1
        if cursor < length, isDigit(text.character(at: cursor)) {
            guard let count = readCount(text, from: &cursor, length: length) else { return nil }
            repeatCount = count
            cursor = skippingLineBlanks(text, from: cursor, length: length)
        }

        if cursor < length,
           let comment = SQLNonCodeSpan.span(at: cursor, in: text, grammar: grammar),
           comment.kind == .lineComment {
            cursor = comment.end
        }
        guard cursor == length || isLineBreak(text.character(at: cursor)) else { return nil }
        return SQLBatchSeparator(range: NSRange(location: offset, length: cursor - offset), repeatCount: repeatCount)
    }

    private static func readCount(_ text: NSString, from cursor: inout Int, length: Int) -> Int? {
        var count = 0
        while cursor < length, isDigit(text.character(at: cursor)) {
            count = count * 10 + Int(text.character(at: cursor) - zero)
            guard count <= Int(Int32.max) else { return nil }
            cursor += 1
        }
        return count > 0 ? count : nil
    }

    private static func startsLine(_ text: NSString, at offset: Int) -> Bool {
        var before = offset - 1
        while before >= 0, isLineBlank(text.character(at: before)) {
            before -= 1
        }
        return before < 0 || isLineBreak(text.character(at: before))
    }

    private static func skippingLineBlanks(_ text: NSString, from offset: Int, length: Int) -> Int {
        var cursor = offset
        while cursor < length, isLineBlank(text.character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    private static func isG(_ unit: UInt16) -> Bool {
        unit == capitalG || unit == smallG
    }

    private static func isO(_ unit: UInt16) -> Bool {
        unit == capitalO || unit == smallO
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= zero && unit <= nine
    }

    private static func isLineBlank(_ unit: UInt16) -> Bool {
        unit == SqlLexer.space || unit == SqlLexer.tab
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == SqlLexer.newline || unit == SqlLexer.carriageReturn
    }
}
