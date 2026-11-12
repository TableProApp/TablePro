import Foundation

/// A `DELIMITER //` line, which changes the text that ends a statement the way the mysql client reads a script.
///
/// The client reads it as the first word of a line, in any case, followed by a space, a tab or the line's end, and only
/// where no statement text is pending. The line goes to no server. The argument is the first word after it, up to a
/// space, or a string quoted with `'`, `"` or a backtick; the rest of the line is ignored. An empty argument, or one
/// holding a backslash, is refused and the delimiter stays as it was. The delimiter then ends a statement wherever it
/// stands in code, inside a word too, matched case for case.
public struct SQLDelimiterDirective: Sendable, Equatable {
    /// The line from its `DELIMITER` to the end of the line, the line feed excluded.
    public let range: NSRange

    /// The delimiter the line sets, nil when the client refuses the argument and keeps the one before.
    public let delimiter: String?

    public init(range: NSRange, delimiter: String?) {
        self.range = range
        self.delimiter = delimiter
    }

    private static let word = Array("delimiter".utf16)

    /// The directive whose `DELIMITER` starts at `offset`, or nil when the line there is not one. `offset` has to be
    /// code where no statement text is pending.
    public static func line(at offset: Int, in text: NSString, length: Int) -> SQLDelimiterDirective? {
        var before = offset - 1
        while before >= 0, isLineBlank(text.character(at: before)) {
            before -= 1
        }
        guard before < 0 || text.character(at: before) == SqlLexer.newline else { return nil }
        return line(startingAt: offset, in: text, length: length)
    }

    /// The directive whose `DELIMITER` starts at `offset`, for a reader that already knows only spaces and tabs stand
    /// before it on its line. `text` has to hold the whole line unless the line ends the text.
    public static func line(startingAt offset: Int, in text: NSString, length: Int) -> SQLDelimiterDirective? {
        let wordEnd = offset + word.count
        guard spellsWord(in: text, at: offset, length: length) else { return nil }
        if wordEnd < length {
            let next = text.character(at: wordEnd)
            guard isLineBlank(next) || next == SqlLexer.newline || next == SqlLexer.carriageReturn else { return nil }
        }
        var lineEnd = wordEnd
        while lineEnd < length, text.character(at: lineEnd) != SqlLexer.newline {
            lineEnd += 1
        }
        // The client reads a line without the carriage return of a CRLF break.
        var argumentEnd = lineEnd
        if argumentEnd > wordEnd, text.character(at: argumentEnd - 1) == SqlLexer.carriageReturn {
            argumentEnd -= 1
        }
        var argument: [UInt16] = []
        for index in wordEnd..<argumentEnd {
            argument.append(text.character(at: index))
        }
        return SQLDelimiterDirective(
            range: NSRange(location: offset, length: lineEnd - offset),
            delimiter: delimiter(fromArgument: argument)
        )
    }

    /// Whether `DELIMITER` and a space or a tab start at `offset`, which is as much as a reader that has not reached
    /// the line's end can tell.
    public static func startsLine(in text: NSString, at offset: Int, length: Int) -> Bool {
        let wordEnd = offset + word.count
        return wordEnd < length && spellsWord(in: text, at: offset, length: length)
            && isLineBlank(text.character(at: wordEnd))
    }

    // ASCII only: the client compares bytes, so `delımiter` is no command.
    private static func spellsWord(in text: NSString, at offset: Int, length: Int) -> Bool {
        guard offset + word.count <= length else { return false }
        for (index, unit) in word.enumerated() where text.character(at: offset + index) | 0x20 != unit {
            return false
        }
        return true
    }

    // As mysql's `get_arg` reads it: a backslash keeps the next unit in an unquoted argument, and a quoted one ends at
    // its first matching quote, or at the line's end when it never closes.
    private static func delimiter(fromArgument argument: [UInt16]) -> String? {
        var index = 0
        while index < argument.count, isArgumentSpace(argument[index]) {
            index += 1
        }
        guard index < argument.count else { return nil }
        var units: [UInt16] = []
        let opener = argument[index]
        if opener == SqlLexer.singleQuote || opener == SqlLexer.doubleQuote || opener == SqlLexer.backtick {
            index += 1
            while index < argument.count, argument[index] != opener {
                units.append(argument[index])
                index += 1
            }
        } else {
            while index < argument.count, argument[index] != SqlLexer.space {
                if argument[index] == SqlLexer.backslash, index + 1 < argument.count {
                    index += 1
                }
                units.append(argument[index])
                index += 1
            }
        }
        guard !units.isEmpty, !units.contains(SqlLexer.backslash) else { return nil }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func isLineBlank(_ unit: UInt16) -> Bool {
        unit == SqlLexer.space || unit == SqlLexer.tab
    }

    // `my_isspace`, which skips the blanks before the argument.
    private static func isArgumentSpace(_ unit: UInt16) -> Bool {
        unit == SqlLexer.space || (unit >= 0x09 && unit <= 0x0D)
    }
}

/// The delimiter a `DELIMITER` line set, which ends a statement wherever it stands in code, matched unit for unit.
public struct SQLClientDelimiter: Sendable, Equatable {
    public let units: [UInt16]

    /// Nil for `;`, which the statement tracker reads.
    public init?(_ text: String) {
        guard text != ";" else { return nil }
        units = Array(text.utf16)
    }

    public func starts(in text: NSString, at offset: Int, length: Int) -> Bool {
        guard offset + units.count <= length else { return false }
        for (index, unit) in units.enumerated() where text.character(at: offset + index) != unit {
            return false
        }
        return true
    }

    /// `word` as read at `start`, cut where the delimiter starts inside it: `END$$` is the word `END`.
    public func cut(
        _ word: (text: String, end: Int),
        readAt start: Int,
        in text: NSString,
        length: Int
    ) -> (text: String, end: Int) {
        let wordStart = word.end - (word.text as NSString).length
        var cursor = max(wordStart, start) + 1
        while cursor < word.end, !starts(in: text, at: cursor, length: length) {
            cursor += 1
        }
        guard cursor < word.end else { return word }
        let raw = text.substring(with: NSRange(location: wordStart, length: cursor - wordStart))
        return (raw.utf16.allSatisfy { $0 < 0x80 } ? raw.uppercased() : raw, cursor)
    }
}
