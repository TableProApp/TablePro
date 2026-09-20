import Foundation

public enum SqlDollarQuote {
    public enum Opener: Sendable {
        case opener(length: Int, tag: String)
        case notOpener
        case needsMoreData
    }

    /// Which dollar quotes an engine reads.
    public enum Style: Sendable, Equatable {
        /// `$$` alone. Snowflake, CQL and Databend read `$name` as a variable, so a tag would swallow one.
        case untagged

        /// `$$` and `$tag$`, PostgreSQL's rule, which DuckDB and Spanner's PostgreSQL dialect share.
        case tagged
    }

    public static let dollar: unichar = 0x24

    public static func isIdentifierStart(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F
    }

    public static func isIdentifierPart(_ ch: unichar) -> Bool {
        isIdentifierStart(ch) || (ch >= 0x30 && ch <= 0x39)
    }

    /// Whether a `$` following this character is part of the preceding identifier, per PostgreSQL's rule that a
    /// dollar quote must be separated from a preceding identifier (so `a$$b` is one identifier, not an opener).
    ///
    /// PostgreSQL's lexer reads every byte from 0x80 up as an identifier character, so a non-ASCII letter glues a
    /// `$` to itself exactly as an ASCII one does.
    public static func isIdentifierContinuation(_ ch: unichar) -> Bool {
        isIdentifierPart(ch) || ch == dollar || ch >= 0x80
    }

    /// Resolves a `$` at `pos` with PostgreSQL's tagged rule.
    public static func scanOpener(at pos: Int, in buffer: NSString, bufLen: Int) -> Opener {
        scanOpener(at: pos, in: buffer, bufLen: bufLen, style: .tagged)
    }

    /// Resolves a `$` at `pos` to a dollar-quote opener, a positional parameter like `$1`, or a non-tag dollar. A `$`
    /// glued to a preceding identifier is not an opener. Returns `needsMoreData` when the buffer ends mid-tag; a
    /// whole-string caller treats that as `notOpener`.
    ///
    /// A tag starts with a letter or an underscore and continues with letters, digits and underscores, where a letter
    /// is any non-ASCII character as well, which is how PostgreSQL accepts `$ü$`.
    public static func scanOpener(at pos: Int, in buffer: NSString, bufLen: Int, style: Style) -> Opener {
        if pos > 0, isIdentifierContinuation(buffer.character(at: pos - 1)) {
            return .notOpener
        }
        guard pos + 1 < bufLen else { return .needsMoreData }
        if buffer.character(at: pos + 1) == dollar {
            return .opener(length: 2, tag: "")
        }
        guard style == .tagged, isTagStart(buffer.character(at: pos + 1)) else { return .notOpener }
        var p = pos + 2
        while p < bufLen {
            let ch = buffer.character(at: p)
            if ch == dollar {
                let tagLen = p - pos - 1
                let tag = buffer.substring(with: NSRange(location: pos + 1, length: tagLen))
                return .opener(length: tagLen + 2, tag: tag)
            }
            if !isTagPart(ch) {
                return .notOpener
            }
            p += 1
        }
        return .needsMoreData
    }

    /// Whether the closing delimiter for `tag` starts at `pos`. The tag match is
    /// exact and case-sensitive, per PostgreSQL.
    public static func matchesClose(at pos: Int, tag: String, in buffer: NSString, bufLen: Int) -> Bool {
        let closeLen = (tag as NSString).length + 2
        guard pos + closeLen <= bufLen else { return false }
        if buffer.character(at: pos) != dollar { return false }
        if buffer.character(at: pos + closeLen - 1) != dollar { return false }
        if tag.isEmpty { return true }
        let tagRange = NSRange(location: pos + 1, length: (tag as NSString).length)
        return buffer.substring(with: tagRange) == tag
    }

    private static func isTagStart(_ ch: unichar) -> Bool {
        isIdentifierStart(ch) || ch >= 0x80
    }

    private static func isTagPart(_ ch: unichar) -> Bool {
        isIdentifierPart(ch) || ch >= 0x80
    }
}
