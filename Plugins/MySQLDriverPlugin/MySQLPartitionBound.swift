import Foundation

/// Turns `information_schema.PARTITIONS` into the text a sidebar row shows.
///
/// The server states a bound in a column that omits the syntax it belongs to. Measured on MariaDB
/// 12.3.3, `PARTITION_DESCRIPTION` holds a bare `2024` or `MAXVALUE` for `RANGE`, a bare
/// `1,2,3` for `LIST`, and null for `HASH` and `KEY`, which state no bound at all. The row has to
/// put the syntax back or the caption reads as an unexplained number.
///
/// The method is matched by prefix rather than by equality because `RANGE COLUMNS` and
/// `LIST COLUMNS` are separate spellings of the same two shapes, and an equality test left both of
/// them without a bound.
internal enum MySQLPartitionBound {
    internal static func display(method: String?, description: String?) -> String? {
        let normalizedMethod = method?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard let value = description?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if normalizedMethod.hasPrefix("RANGE") {
            return "VALUES LESS THAN (\(value))"
        }
        if normalizedMethod.hasPrefix("LIST") {
            return "VALUES IN (\(value))"
        }
        return value
    }
}
