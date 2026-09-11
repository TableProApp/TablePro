import Foundation

/// The single owner of how SQL Server spells a string literal carrying user text.
///
/// A plain `'…'` is a `varchar` literal, so the server converts it to the database's collation
/// code page while it parses the batch. On a non-Unicode collation every character outside that
/// page becomes `?`, and it happens whatever the target column is: inserting `'日本語'` into an
/// `NVARCHAR(50)` column stores `??????`, and `WHERE n = '日本語'` then matches the row that was
/// damaged earlier rather than the row that holds the text. `N'…'` is an `nvarchar` literal and is
/// converted by nothing. It costs nothing on ASCII, where `N'abc' = 'abc'`.
///
/// Only text the user or the catalog supplies goes through here. A number, an identifier, a `0x`
/// binary literal and a fixed catalog constant such as `'PRIMARY KEY'` must stay as they are.
public enum MSSQLStringLiteral {
    public static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quoted(_ value: String) -> String {
        "N'\(escaped(value))'"
    }

    /// `LIKE` takes its pattern as an ordinary string literal, so the prefix belongs here too. The
    /// wildcards the user typed are escaped and declared with `ESCAPE '\'`, which stays a plain
    /// literal because a backslash is ASCII.
    public static func likePattern(_ value: String, prefixWildcard: Bool, suffixWildcard: Bool) -> String {
        let body = escapeForLike(value)
        let pattern = (prefixWildcard ? "%" : "") + body + (suffixWildcard ? "%" : "")
        return "N'\(pattern)' ESCAPE '\\'"
    }

    public static func escapeForLike(_ value: String) -> String {
        escaped(
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        )
    }

    /// The `LIKE` arms of the shared filter builder write their own literal rather than asking the
    /// driver for one, so SQL Server answers them here and lets everything else fall through.
    public static func likeCondition(quotedColumn: String, op: String, value: String) -> String? {
        switch op {
        case "CONTAINS":
            return "\(quotedColumn) LIKE \(likePattern(value, prefixWildcard: true, suffixWildcard: true))"
        case "NOT CONTAINS":
            return "\(quotedColumn) NOT LIKE \(likePattern(value, prefixWildcard: true, suffixWildcard: true))"
        case "STARTS WITH":
            return "\(quotedColumn) LIKE \(likePattern(value, prefixWildcard: false, suffixWildcard: true))"
        case "ENDS WITH":
            return "\(quotedColumn) LIKE \(likePattern(value, prefixWildcard: true, suffixWildcard: false))"
        default:
            return nil
        }
    }
}
