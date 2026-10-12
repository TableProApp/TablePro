import Foundation

/// One partition of a partitioned table.
///
/// `PluginTableInfo` cannot carry this. A PostgreSQL partition is a relation whose name is unique
/// within its schema, but a MySQL or Oracle partition is metadata on one table object, and its name
/// is unique only within that table: every partitioned table's `p0` would collide with every other
/// table's `p0` and with a real table called `p0`, because a table's identity is its name, type and
/// schema.
///
/// `isSeparateRelation` is what tells the two apart. It is a per-partition answer rather than a
/// per-engine one, because PostgreSQL can hold both a partition that is a plain table and one that
/// is itself subpartitioned, and a future engine may mix them further.
public struct PluginPartitionInfo: Codable, Sendable {
    /// The partition's own name, unqualified.
    public let name: String

    /// The schema the partition itself lives in, which is not always its parent's: PostgreSQL
    /// allows `CREATE TABLE archive.orders_2023 PARTITION OF public.orders`. Nil when the partition
    /// is not a relation and so has no schema of its own.
    public let schema: String?

    /// The bound, ready to display, already spelled in the engine's own dialect by its driver:
    /// `FROM ('2024-01-01') TO ('2024-02-01')`, `IN ('de', 'fr')`, `VALUES LESS THAN (2024)`,
    /// `DEFAULT`. Nil where the engine states no bound, which is every HASH and KEY partition on
    /// MySQL and every partition on Oracle, whose `HIGH_VALUE` is a LONG column the driver cannot
    /// read.
    public let bound: String?

    /// Where the partition sits in its parent's declared order, 1-based, for engines that order
    /// partitions rather than naming a bound.
    public let ordinalPosition: Int?

    /// The engine's own row estimate, which is not a count.
    public let rowCount: Int?

    /// What kind of relation the partition is, in the same vocabulary `PluginTableInfo.type` uses,
    /// or nil when it is not a relation at all.
    ///
    /// The kind has to travel, not just the fact of being one. A PostgreSQL partition can be a
    /// plain table, a partitioned table, or a foreign table, and the three are not interchangeable:
    /// a foreign table is read-only, so calling one a plain table offers Truncate on data that
    /// lives on another server.
    public let relationType: String?

    /// Whether the partition is addressable in its own right. True on PostgreSQL, where a partition
    /// can be opened, dropped and truncated by name; false on MySQL and Oracle, where it can only be
    /// reached through its parent.
    public var isSeparateRelation: Bool { relationType != nil }

    /// Whether this partition is itself partitioned, so it holds partitions of its own.
    public let isSubpartitioned: Bool

    /// The partition this one subdivides, for an engine that reports subpartitions in the same list
    /// as their parents. Nil for a top-level partition.
    public let parentPartitionName: String?

    public init(
        name: String,
        schema: String? = nil,
        bound: String? = nil,
        ordinalPosition: Int? = nil,
        rowCount: Int? = nil,
        relationType: String?,
        isSubpartitioned: Bool = false,
        parentPartitionName: String? = nil
    ) {
        self.name = name
        self.schema = schema
        self.bound = bound
        self.ordinalPosition = ordinalPosition
        self.rowCount = rowCount
        self.relationType = relationType
        self.isSubpartitioned = isSubpartitioned
        self.parentPartitionName = parentPartitionName
    }

    /// The relation spellings a partition can legitimately carry, normalised so `FOREIGN_TABLE`
    /// and `foreign table` are one answer. Anything else, such as the `partition` a Kafka broker
    /// partition declares, is not a relation and gets no relation type.
    public static func relationType(forDeclaredType declaredType: String) -> String? {
        let normalized = declaredType
            .replacingOccurrences(of: "_", with: " ")
            .uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let known: Set<String> = [
            "TABLE", "BASE TABLE", "PARTITIONED TABLE", "FOREIGN TABLE", "SYSTEM TABLE", "EXTERNAL TABLE"
        ]
        return known.contains(normalized) ? normalized : nil
    }
}
