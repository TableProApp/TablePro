import CSQLite
import Foundation

/// What `sqlite3_prepare_v2` leaves unread after the statement it compiled.
public enum SQLiteStatementTail {
    /// Whether `tail` holds anything but blanks, comments and `;`, as SQLite's tokenizer reads them. It never prepares
    /// the tail: preparing a `PRAGMA` already applies it.
    public static func holdsStatement(_ tail: UnsafePointer<CChar>) -> Bool {
        afterTrivia(tail).pointee != 0
    }

    /// Whether `text` opens with a `PRAGMA`, `EXPLAIN` or `EXPLAIN QUERY PLAN` before it included, and holds a second
    /// statement after it. Preparing the `PRAGMA` would already apply it, so this is asked before anything is prepared.
    /// The `PRAGMA` ends where `sqlite3_complete` first says the text so far is a whole statement.
    public static func pragmaHoldsSecondStatement(_ text: UnsafePointer<CChar>) -> Bool {
        var start = afterTrivia(text)
        for keyword in ["explain", "query", "plan"] where startsWord(keyword, at: start) {
            start = afterTrivia(start + keyword.utf8.count)
        }
        guard startsWord("pragma", at: start) else { return false }
        let length = strlen(text)
        var prefix = [CChar](repeating: 0, count: length + 1)
        for end in 0..<length where text[end] == semicolon {
            prefix.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress?.update(from: text, count: end + 1)
                buffer[end + 1] = 0
            }
            guard sqlite3_complete(prefix) != 0 else { continue }
            return holdsStatement(text + end + 1)
        }
        return false
    }

    private static func afterTrivia(_ text: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
        var cursor = text
        while true {
            switch cursor.pointee {
            case 0x09...0x0D, 0x20, semicolon:
                cursor += 1
            case dash where cursor[1] == dash:
                cursor += 2
                while cursor.pointee != 0, cursor.pointee != newline {
                    cursor += 1
                }
            case slash where cursor[1] == star:
                cursor += 2
                while cursor.pointee != 0, !(cursor.pointee == star && cursor[1] == slash) {
                    cursor += 1
                }
                if cursor.pointee != 0 {
                    cursor += 2
                }
            default:
                return cursor
            }
        }
    }

    private static func startsWord(_ word: String, at text: UnsafePointer<CChar>) -> Bool {
        let letters = Array(word.utf8)
        for (offset, letter) in letters.enumerated() where UInt8(bitPattern: text[offset]) | 0x20 != letter {
            return false
        }
        return !continuesName(UInt8(bitPattern: text[letters.count]))
    }

    // SQLite's `IdChar`: ASCII letters, digits, `_`, `$` and every byte from 0x80 up.
    private static func continuesName(_ byte: UInt8) -> Bool {
        let lowered = byte | 0x20
        return (lowered >= 0x61 && lowered <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "$") || byte >= 0x80
    }

    private static let semicolon = CChar(UInt8(ascii: ";"))
    private static let dash = CChar(UInt8(ascii: "-"))
    private static let slash = CChar(UInt8(ascii: "/"))
    private static let star = CChar(UInt8(ascii: "*"))
    private static let newline = CChar(UInt8(ascii: "\n"))
}
