import Foundation

/// Substring tests written without LIKE, for an engine that refuses a LIKE pattern past a byte limit.
///
/// `operand` is the SQL expression searched, `literal` an already quoted string literal of the plain value, with no
/// LIKE escaping, since nothing here reads `%` or `_` as a wildcard. `fold` names the case-fold function applied to
/// both sides, such as `LOWER`. Measured on SQLite 3.54: every form gives NULL for a NULL operand, as LIKE does, so a
/// "does not contain" still leaves NULL rows out.
public enum SQLSubstringMatch {
    public static func contains(_ operand: String, literal: String, fold: String) -> String {
        "instr(\(fold)(\(operand)), \(fold)(\(literal))) > 0"
    }

    public static func notContains(_ operand: String, literal: String, fold: String) -> String {
        "instr(\(fold)(\(operand)), \(fold)(\(literal))) = 0"
    }

    public static func startsWith(_ operand: String, literal: String, fold: String) -> String {
        "instr(\(fold)(\(operand)), \(fold)(\(literal))) = 1"
    }

    /// Compares the tail, because `instr` reports only the first match: measured on SQLite 3.54, 'abab' ends with
    /// 'ab', yet its first 'ab' is at 1, not 3. The value must not be empty: `substr(x, 0)` is the whole of `x`, so an
    /// empty one matches no row where `LIKE '%'` matches every row. An empty value never exceeds a limit anyway.
    public static func endsWith(_ operand: String, literal: String, fold: String) -> String {
        "substr(\(fold)(\(operand)), -length(\(literal))) = \(fold)(\(literal))"
    }

    /// Whether the LIKE pattern as sent is longer than `limit` bytes of UTF-8: `likePatternBody` with its wildcard
    /// escapes, plus the `wildcards` `%` the caller adds. Measured on SQLite 3.54 with the limit at 50: a 50-byte
    /// pattern runs and a 51-byte one is "LIKE or GLOB pattern too complex", and a doubled quote counts once. A SQL
    /// literal body therefore over-counts each quote, which only switches to the LIKE-free form early.
    public static func exceeds(_ likePatternBody: String, wildcards: Int, limit: Int?) -> Bool {
        guard let limit else { return false }
        return likePatternBody.utf8.count + wildcards > limit
    }
}
