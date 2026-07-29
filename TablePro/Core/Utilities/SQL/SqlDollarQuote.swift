//
//  SqlDollarQuote.swift
//  TablePro
//

import Foundation

enum SqlDollarQuote {
    enum Opener {
        case opener(length: Int, tag: String)
        case notOpener
        case needsMoreData
    }

    static let dollar: unichar = 0x24

    static func isIdentifierStart(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F
    }

    static func isIdentifierPart(_ ch: unichar) -> Bool {
        isIdentifierStart(ch) || (ch >= 0x30 && ch <= 0x39)
    }

    /// Whether a `$` following this character is part of the preceding identifier,
    /// per PostgreSQL's rule that a dollar quote must be separated from a
    /// preceding identifier by whitespace (so `a$$b` is one identifier, not an
    /// opener).
    static func isIdentifierContinuation(_ ch: unichar) -> Bool {
        isIdentifierPart(ch) || ch == dollar
    }

    /// Resolves a `$` at `pos` to a dollar-quote opener, a positional parameter
    /// like `$1`, or a non-tag dollar. A `$` glued to a preceding identifier is
    /// not an opener. Returns `needsMoreData` when the buffer ends mid-tag; a
    /// whole-string caller treats that as `notOpener`.
    static func scanOpener(at pos: Int, in buffer: NSString, bufLen: Int) -> Opener {
        if pos > 0, isIdentifierContinuation(buffer.character(at: pos - 1)) {
            return .notOpener
        }
        var p = pos + 1
        while p < bufLen {
            let ch = buffer.character(at: p)
            if ch == dollar {
                let tagLen = p - pos - 1
                if tagLen == 0 {
                    return .opener(length: 2, tag: "")
                }
                if !isIdentifierStart(buffer.character(at: pos + 1)) {
                    return .notOpener
                }
                let tag = buffer.substring(with: NSRange(location: pos + 1, length: tagLen))
                return .opener(length: tagLen + 2, tag: tag)
            }
            if !isIdentifierPart(ch) {
                return .notOpener
            }
            p += 1
        }
        return .needsMoreData
    }

    /// Whether the closing delimiter for `tag` starts at `pos`. The tag match is
    /// exact and case-sensitive, per PostgreSQL.
    static func matchesClose(at pos: Int, tag: String, in buffer: NSString, bufLen: Int) -> Bool {
        let closeLen = (tag as NSString).length + 2
        guard pos + closeLen <= bufLen else { return false }
        if buffer.character(at: pos) != dollar { return false }
        if buffer.character(at: pos + closeLen - 1) != dollar { return false }
        if tag.isEmpty { return true }
        let tagRange = NSRange(location: pos + 1, length: (tag as NSString).length)
        return buffer.substring(with: tagRange) == tag
    }
}
