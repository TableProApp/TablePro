import Foundation

/// One partition of a partitioned table, as the sidebar and the MCP tools see it.
///
/// A partition is not a `TableInfo`. On PostgreSQL it happens to be a relation and can be opened,
/// dropped and truncated by name, but on MySQL and Oracle it is a segment of one table whose name
/// is unique only within that table, so two tables' `p0` are different objects with the same name.
/// `isSeparateRelation` is what decides which of the two the row is, and `tableRef` is nil for the
/// ones that cannot be addressed on their own.
struct PartitionInfo: Identifiable, Hashable, Sendable {
    let name: String
    let schema: String?
    let bound: String?
    let ordinalPosition: Int?
    let rowCount: Int?
    /// What the partition is as an object, or nil when it is not a relation at all. The kind
    /// travels rather than a bare flag: a PostgreSQL partition can be a foreign table, which is
    /// read-only, and calling one a plain table offers Truncate on another server's data.
    let relationType: TableInfo.TableType?

    var isSeparateRelation: Bool { relationType != nil }
    let isSubpartitioned: Bool
    let parentPartitionName: String?

    /// Unique within one parent table, which is the only scope a partition list is ever built in.
    /// The parent partition is part of it because MySQL allows a subpartition to repeat a name
    /// another partition's subpartition already uses.
    ///
    /// Each component is escaped, because a period is legal inside a quoted identifier: joined
    /// raw, schema `a.b` with name `c` and schema `a` with name `b.c` produce one id for two
    /// partitions, and this id keys the outline's rows.
    var id: String {
        [parentPartitionName, schema, name].map(Self.escaped).joined(separator: "|")
    }

    private static func escaped(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    init(
        name: String,
        schema: String? = nil,
        bound: String? = nil,
        ordinalPosition: Int? = nil,
        rowCount: Int? = nil,
        relationType: TableInfo.TableType?,
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

    /// The partition seen as a table, for the engines where it is one. A PostgreSQL partition keeps
    /// every table affordance this way, including being opened in a tab, dropped and favourited,
    /// and it carries its own schema rather than its parent's.
    ///
    /// The bound is not folded into `comment`: the comment is what the server stores against the
    /// object, the sidebar hides it behind a setting, and a bound put there would vanish with it.
    var asTableInfo: TableInfo? {
        guard let relationType else { return nil }
        return TableInfo(
            name: name,
            type: relationType,
            rowCount: rowCount,
            schema: schema
        )
    }
}
