import Foundation

// Line facts for cutting a SQL Server script at its GO lines, read off a buffer holding only the last chunks.
public enum SQLFileBatchLines {
    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    // A step can read a whole literal or comment, so the last units read decide.
    public static func holdsOnlyBlanks(_ buffer: NSString, from start: Int, to end: Int, before: Bool) -> Bool {
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

    public static func lineBreak(in buffer: NSString, from start: Int, length: Int) -> Int? {
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

    // How far below its first line the text the server receives starts once its leading blanks are trimmed.
    public static func leadingLineFeeds(in text: NSString?) -> Int {
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
