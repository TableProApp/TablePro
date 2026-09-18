import Foundation

/// One partition row in the object tree, named by everything it takes to reach it.
///
/// A partition is addressed through its parent, never on its own, because on MySQL and Oracle its
/// name is unique only within that parent. `tableRef` is what a partition that happens to be a
/// relation offers instead: PostgreSQL partitions go through it and keep every table affordance,
/// including opening in a tab, dropping, truncating and favouriting, and they carry their own
/// schema rather than the parent's, which need not be the same one.
struct DatabaseTreePartitionRef: Hashable, Identifiable, Sendable {
    let parent: DatabaseTreeTableRef
    let partition: PartitionInfo

    var id: String {
        "\(parent.id)\u{1}\(partition.id)"
    }

    /// The partition seen as a table, for the engines where it is one. Nil says the row cannot be
    /// opened, dropped or renamed, which is what every menu and the double-click resolver read.
    var tableRef: DatabaseTreeTableRef? {
        guard let table = partition.asTableInfo else { return nil }
        return DatabaseTreeTableRef(
            database: parent.database,
            schema: partition.schema ?? parent.schema,
            table: table
        )
    }
}
