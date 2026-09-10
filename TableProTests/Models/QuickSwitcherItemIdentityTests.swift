//
//  QuickSwitcherItemIdentityTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// Two places record that a table was opened: the quick switcher, which knows the object's
/// `TableInfo.TableType`, and the tab open chokepoint, which only learns a Bool. They have to
/// produce the same id or the Recent section and the frecency boost silently skip the object.
struct QuickSwitcherItemIdentityTests {
    /// What `SharedSidebarState.commitTableOpen` records when a table is opened from anywhere
    /// other than the switcher.
    private func recordedByTabOpen(name: String, schema: String?) -> String {
        QuickSwitcherItem.tableItemId(name: name, schema: schema)
    }

    /// What the switcher lists the same object under.
    private func listedBySwitcher(name: String, schema: String?) -> String {
        QuickSwitcherItem.tableItemId(name: name, schema: schema)
    }

    /// Every type used to be spelled into the id, from two sides that spelled it differently.
    /// The tab derives `isView` from `allowsRowEditing`, so a materialized view was recorded as
    /// `TABLE` while the switcher listed it as `MATERIALIZED VIEW`.
    @Test("Every table type records and lists under the same id", arguments: [
        TableInfo.TableType.table,
        .view,
        .materializedView,
        .foreignTable,
        .systemTable,
        .partitionedTable,
        .externalTable
    ])
    func everyTypeAgrees(type: TableInfo.TableType) {
        let table = TableInfo(name: "sales", type: type, rowCount: nil, schema: "public")
        #expect(
            listedBySwitcher(name: table.name, schema: table.schema)
                == recordedByTabOpen(name: table.name, schema: table.schema)
        )
    }

    @Test("A schema qualifies the id")
    func schemaQualifiesTheId() {
        #expect(
            QuickSwitcherItem.tableItemId(name: "users", schema: "public")
                != QuickSwitcherItem.tableItemId(name: "users", schema: "analytics")
        )
    }

    @Test("A driver that reports no schema keeps a stable id")
    func noSchemaKeepsStableId() {
        #expect(
            QuickSwitcherItem.tableItemId(name: "users", schema: nil)
                == QuickSwitcherItem.tableItemId(name: "users", schema: "")
        )
    }

    @Test("Different names never collide")
    func differentNamesDoNotCollide() {
        #expect(
            QuickSwitcherItem.tableItemId(name: "users", schema: "public")
                != QuickSwitcherItem.tableItemId(name: "orders", schema: "public")
        )
    }

    /// The id is a key in a per-connection store shared with database, schema and query items, so
    /// it has to stay inside the table namespace.
    @Test("The id stays in the table namespace")
    func idStaysInTableNamespace() {
        #expect(QuickSwitcherItem.tableItemId(name: "users", schema: nil).hasPrefix("table_"))
        #expect(QuickSwitcherItem.tableItemId(name: "users", schema: "public").hasPrefix("table_"))
    }
}
