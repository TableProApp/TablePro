import Foundation

/// Pure helper functions for SQL keyword auto-uppercase.
/// Extracted from SQLEditorCoordinator for testability.
enum KeywordUppercaseHelper {

    /// Checks if a typed string is a word boundary character (triggers keyword check).
    static func isWordBoundary(_ string: String) -> Bool {
        guard (string as NSString).length == 1, let ch = string.unicodeScalars.first else { return false }
        switch ch {
        case " ", "\t", "\n", "\r", "(", ")", ",", ";":
            return true
        default:
            return false
        }
    }

    /// Checks if a UTF-16 character is part of a SQL identifier (a-z, A-Z, 0-9, _).
    static func isWordCharacter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) ||
        (ch >= 0x30 && ch <= 0x39) || ch == 0x5F
    }

    /// Scans backwards up to 2,000 characters to determine if `position` is inside
    /// a protected context (string literal, comment, backtick identifier, dollar-quote).
    /// Keywords inside protected contexts should NOT be uppercased.
    static func isInsideProtectedContext(_ text: NSString, at position: Int) -> Bool {
        let scanStart = max(0, position - 2_000)
        var inSingleQuote = false
        var inDoubleQuote = false
        var inBacktick = false
        var inLineComment = false
        var inBlockComment = false
        var inDollarQuote = false
        var i = scanStart

        while i < position {
            let ch = text.character(at: i)

            if inBlockComment {
                if ch == 0x2A && i + 1 < position && text.character(at: i + 1) == 0x2F {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if inLineComment {
                if ch == 0x0A { inLineComment = false }
                i += 1
                continue
            }
            if inDollarQuote {
                if ch == 0x24 && i + 1 < position && text.character(at: i + 1) == 0x24 {
                    inDollarQuote = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if ch == 0x5C && (inSingleQuote || inDoubleQuote) {
                i += 2
                continue
            }

            switch ch {
            case 0x27: if !inDoubleQuote && !inBacktick { inSingleQuote.toggle() }
            case 0x22: if !inSingleQuote && !inBacktick { inDoubleQuote.toggle() }
            case 0x60: if !inSingleQuote && !inDoubleQuote { inBacktick.toggle() }
            case 0x23:
                if !inSingleQuote && !inDoubleQuote && !inBacktick {
                    inLineComment = true
                }
            case 0x2D:
                if !inSingleQuote && !inDoubleQuote && !inBacktick &&
                   i + 1 < position && text.character(at: i + 1) == 0x2D {
                    inLineComment = true
                    i += 2
                    continue
                }
            case 0x2F:
                if !inSingleQuote && !inDoubleQuote && !inBacktick &&
                   i + 1 < position && text.character(at: i + 1) == 0x2A {
                    inBlockComment = true
                    i += 2
                    continue
                }
            case 0x24:
                if !inSingleQuote && !inDoubleQuote && !inBacktick &&
                   i + 1 < position && text.character(at: i + 1) == 0x24 {
                    inDollarQuote.toggle()
                    i += 2
                    continue
                }
            default: break
            }
            i += 1
        }

        return inSingleQuote || inDoubleQuote || inBacktick || inLineComment || inBlockComment || inDollarQuote
    }

    /// Extracts the word immediately before `position` in `text` by scanning backwards.
    /// Returns nil if no word found or the word is not a SQL keyword.
    static func keywordBeforePosition(_ text: NSString, at position: Int) -> (word: String, range: NSRange)? {
        var wordStart = position
        while wordStart > 0 {
            let ch = text.character(at: wordStart - 1)
            guard isWordCharacter(ch) else { break }
            wordStart -= 1
        }

        let wordLength = position - wordStart
        guard wordLength > 0 else { return nil }

        let word = text.substring(with: NSRange(location: wordStart, length: wordLength))
        guard SQLKeywords.keywordSet.contains(word.lowercased()) else { return nil }
        guard !isInsideProtectedContext(text, at: wordStart) else { return nil }

        let uppercased = word.uppercased()
        guard uppercased != word else { return nil }

        return (word: word, range: NSRange(location: wordStart, length: wordLength))
    }
}
