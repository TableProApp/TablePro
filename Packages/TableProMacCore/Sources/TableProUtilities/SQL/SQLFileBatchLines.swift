//
//  SQLFileBatchLines.swift
//  TablePro
//

import Foundation

/// What the import parser needs to know about lines to cut a SQL Server script at its `GO` lines, read off a buffer
/// that holds only the part of the file the last chunks brought in.
enum SQLFileBatchLines {
    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    /// Whether only spaces and tabs follow the last line break once the units in `start..<end` are read, given whether
    /// that held before them. A step can read a whole literal or comment, so it is the last units that decide.
    static func holdsOnlyBlanks(_ buffer: NSString, from start: Int, to end: Int, before: Bool) -> Bool {
        var index = end - 1
        while index >= start {
            let unit = buffer.character(at: index)
            if unit == lineFeed || unit == carriageReturn {
                return true
            }
            if unit != space && unit != tab {
                return false
            }
            index -= 1
        }
        return before
    }

    /// The first line break at or after `start`, or nil when the buffer ends first.
    static func lineBreak(in buffer: NSString, from start: Int, length: Int) -> Int? {
        var index = start
        while index < length {
            let unit = buffer.character(at: index)
            if unit == lineFeed || unit == carriageReturn {
                return index
            }
            index += 1
        }
        return nil
    }

    /// How many line feeds the blanks at the start of `text` hold, which is how far below its first line the text the
    /// server receives begins once those blanks are trimmed.
    static func leadingLineFeeds(in text: NSString?) -> Int {
        guard let text else { return 0 }
        var count = 0
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            guard let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
            if unit == lineFeed {
                count += 1
            }
            index += 1
        }
        return count
    }
}
