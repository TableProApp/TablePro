import Foundation

/// Turns what `pg_get_expr(relpartbound, oid)` returns into the text a sidebar row shows.
///
/// Measured on PostgreSQL 17.11, the server spells a bound as
/// `FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')`, `FOR VALUES IN ('de', 'fr', 'es')`,
/// `FOR VALUES WITH (modulus 4, remainder 0)`, or a bare `DEFAULT`. Every row under one parent
/// repeats the same `FOR VALUES ` prefix, so it distinguishes nothing and only pushes the part that
/// does distinguish them out of the visible width. `DEFAULT` carries no prefix and is left alone.
///
/// A legacy `INHERITS` child has no bound at all and comes back null.
internal enum PostgreSQLPartitionBound {
    private static let prefix = "FOR VALUES "

    internal static func display(rawExpression: String?) -> String? {
        guard let trimmed = rawExpression?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        let remainder = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? trimmed : remainder
    }
}
