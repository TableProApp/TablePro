import Foundation
@testable import TablePro
import Testing

struct TableDetailTreeTests {
    private let everything = TableDetailCapabilities(foreignKeys: true, checks: true, triggers: true)

    private func orders(_ type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "shop", schema: "public", table: TableInfo(name: "orders", type: type, rowCount: nil, schema: "public")
        )
    }

    private func groups(
        _ type: TableInfo.TableType,
        capabilities: TableDetailCapabilities? = nil,
        showsPartitions: Bool = true
    ) -> [TableDetailGroupKind] {
        TableDetailGroupResolver.groups(
            for: type, capabilities: capabilities ?? everything, showsPartitions: showsPartitions
        )
    }

    @Test("A table lists every group its engine can read, in a fixed order")
    func tableGroups() {
        #expect(groups(.table) == [.columns, .indexes, .foreignKeys, .checks, .triggers])
    }

    @Test("A group the engine cannot read is not listed")
    func capabilitiesGateGroups() {
        let keysOnly = TableDetailCapabilities(foreignKeys: true, checks: false, triggers: false)
        let none = TableDetailCapabilities(foreignKeys: false, checks: false, triggers: false)

        #expect(groups(.table, capabilities: keysOnly) == [.columns, .indexes, .foreignKeys])
        #expect(groups(.table, capabilities: none) == [.columns, .indexes])
    }

    @Test("A view lists columns, a materialized view adds indexes, and a sequence lists nothing")
    func relationTypesGateGroups() {
        #expect(groups(.view) == [.columns])
        #expect(groups(.foreignTable) == [.columns])
        #expect(groups(.materializedView) == [.columns, .indexes])
        #expect(groups(.sequence).isEmpty)
        #expect(!TableDetailGroupResolver.listsDetails(of: .sequence))
        #expect(TableDetailGroupResolver.listsDetails(of: .view))
    }

    @Test("A partitioned table's partitions come last, and only while Partitions is on")
    func partitionsGroupFollowsItsOption() {
        #expect(groups(.partitionedTable) == [.columns, .indexes, .foreignKeys, .checks, .triggers, .partitions])
        #expect(groups(.partitionedTable, showsPartitions: false) == [.columns, .indexes, .foreignKeys, .checks, .triggers])
        #expect(!groups(.table).contains(.partitions))
    }

    @Test("A list reads when stale, and again when the user opens a group whose read failed")
    func readsOnDisclosureFollowsStalenessAndTheUser() {
        #expect(TableDetailGroupResolver.readsOnDisclosure(needsFetch: true, phase: .idle, origin: .restore))
        #expect(!TableDetailGroupResolver.readsOnDisclosure(needsFetch: false, phase: .loaded, origin: .user))
        #expect(TableDetailGroupResolver.readsOnDisclosure(needsFetch: false, phase: .failed("denied"), origin: .user))
        #expect(!TableDetailGroupResolver.readsOnDisclosure(needsFetch: false, phase: .failed("denied"), origin: .restore))
        #expect(!TableDetailGroupResolver.readsOnDisclosure(needsFetch: false, phase: .failed("denied"), origin: .search))
    }

    @Test("A two-column foreign key is one row, with both column pairs in key order")
    func foreignKeysGroupByConstraint() {
        let list = TableDetailList.foreignKeys([
            TestFixtures.makeForeignKeyInfo(
                name: "orders_customer_fk", column: "customer_id", referencedTable: "customers", referencedColumn: "id"
            ),
            TestFixtures.makeForeignKeyInfo(
                name: "orders_customer_fk", column: "customer_region", referencedTable: "customers", referencedColumn: "region"
            ),
            TestFixtures.makeForeignKeyInfo(
                name: "orders_coupon_fk", column: "coupon_id", referencedTable: "coupons", referencedColumn: "id"
            ),
        ])

        let items = TableDetailRows.items(in: list)
        let names = items.map { $0.name }

        #expect(names == ["orders_customer_fk", "orders_coupon_fk"])
        #expect(list.count == 2)
        guard case .foreignKey(let key) = items.first else {
            Issue.record("The first row is not a foreign key")
            return
        }
        #expect(key.columns == ["customer_id", "customer_region"])
        #expect(key.referencedColumns == ["id", "region"])
    }

    @Test("Items that share a name get keys of their own, and the first keeps its name")
    func sameNamedItemsGetTheirOwnKeys() {
        let keys = TableDetailRows.uniqueKeys(for: ["", "", "total_positive", ""])

        #expect(Set(keys).count == 4)
        #expect(keys[2] == "total_positive")

        let entries = TableDetailRows.entries(
            for: .checks([
                CheckConstraintInfo(name: "", expression: "total > 0"),
                CheckConstraintInfo(name: "", expression: "total < 1000"),
            ]),
            table: orders()
        )
        let entryKeys = entries.map { $0.key }
        #expect(Set(entryKeys).count == 2)
    }

    @Test("A detail row carries the table it belongs to")
    func detailRowsCarryTheirTable() {
        let entries = TableDetailRows.entries(
            for: .columns([TestFixtures.makeColumnInfo(name: "id", dataType: "integer")]), table: orders()
        )

        guard case .detail(let detail) = entries.first?.row else {
            Issue.record("A column is not a detail row")
            return
        }
        #expect(detail.table == orders())
        #expect(detail.item.name == "id")
        #expect(TableDetailRows.entries(for: .columns([]), table: orders()).isEmpty)
    }

    @Test("A trigger listed under its table names that table, even when the driver left it out")
    func triggersBelongToTheirTable() {
        let bare = TriggerInfo(name: "orders_audit", timing: "AFTER", event: "INSERT", statement: "")

        let entries = TableDetailRows.entries(for: .triggers([bare]), table: orders())

        guard case .trigger(let ref) = entries.first?.row else {
            Issue.record("A trigger is not a trigger row")
            return
        }
        #expect(ref.listedUnderTable)
        #expect(ref.database == "shop")
        #expect(ref.trigger.table == "orders")
        #expect(ref.trigger.schema == "public")
        #expect(ref.objectRef.table == "orders")
        #expect(sameFiring(ref.trigger, bare))
    }

    @Test("A trigger the driver placed keeps its own table and schema")
    func placedTriggersKeepTheirPlace() {
        let placed = TriggerInfo(
            name: "audit", timing: "BEFORE", event: "UPDATE", statement: "", table: "orders_log", schema: "audit"
        )

        let owned = TableDetailRows.owned(placed, by: orders())

        #expect(owned == placed)
    }

    @Test("A group's expansion key is its table's key and its kind")
    func groupExpansionKey() {
        let group = DatabaseTreeTableDetailGroupRef(table: orders(), kind: .checks)

        #expect(group.expansionKey == DatabaseTableDetailGroupKey(
            table: DatabaseTableKey(database: "shop", schema: "public", table: "orders"), group: .checks
        ))
        #expect(TableDetailGroupKind.partitions.detailKind == nil)
        #expect(TableDetailGroupKind.checks.detailKind == .checks)
    }

    private func sameFiring(_ lhs: TriggerInfo, _ rhs: TriggerInfo) -> Bool {
        [lhs.name, lhs.timing, lhs.event, lhs.statement] == [rhs.name, rhs.timing, rhs.event, rhs.statement]
    }
}
