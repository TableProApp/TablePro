import Foundation
@testable import TablePro
import Testing

struct TableDetailRowLogicTests {
    private func index(_ columns: [String], unique: Bool = false, primary: Bool = false) -> TableDetailItem {
        .index(IndexInfo(name: "orders_idx", columns: columns, isUnique: unique, isPrimary: primary, type: "BTREE"))
    }

    @Test("Every group has its own title, and the Structure tab's glyph where it has one")
    func groupTitlesAndIcons() {
        let titles = TableDetailGroupKind.allCases.map { TableDetailRowLogic.title(for: $0) }

        #expect(Set(titles).count == titles.count)
        #expect(TableDetailRowLogic.title(for: .columns) == String(localized: "Columns"))
        #expect(TableDetailRowLogic.title(for: .checks) == String(localized: "Checks"))
        #expect(TableDetailRowLogic.iconName(for: .indexes) == "list.bullet")
        #expect(TableDetailRowLogic.iconName(for: .foreignKeys) == "link")
        #expect(TableDetailRowLogic.iconName(for: .checks) == "checkmark.shield")
        #expect(TableDetailRowLogic.iconName(for: .triggers) == SidebarObjectKind.trigger.iconName)
        #expect(TableDetailRowLogic.iconName(for: .partitions) == SidebarPartitionRow.iconName)
    }

    @Test("A primary key column and the primary index wear the key glyph")
    func primaryKeysWearTheKey() {
        let key = TableDetailItem.column(TestFixtures.makeColumnInfo(name: "id", isPrimaryKey: true))
        let plain = TableDetailItem.column(TestFixtures.makeColumnInfo(name: "total", isPrimaryKey: false))

        #expect(TableDetailRowLogic.iconName(for: key) == "key")
        #expect(TableDetailRowLogic.iconName(for: plain) != "key")
        #expect(TableDetailRowLogic.iconName(for: index(["id"], unique: true, primary: true)) == "key")
        #expect(TableDetailRowLogic.iconName(for: index(["total"])) == "list.bullet")
    }

    @Test("A column's caption is its type as the driver reports it")
    func columnCaption() {
        let column = TableDetailItem.column(TestFixtures.makeColumnInfo(name: "total", dataType: "numeric(10,2)"))

        #expect(TableDetailRowLogic.caption(for: column) == "numeric(10,2)")
    }

    @Test("An index's caption lists its columns and says when it is unique")
    func indexCaption() {
        #expect(TableDetailRowLogic.caption(for: index(["customer_id", "created_at"])) == "customer_id, created_at")
        #expect(
            TableDetailRowLogic.caption(for: index(["email"], unique: true))
                == String(format: String(localized: "%@ (unique)"), "email")
        )
    }

    @Test("A foreign key's caption names the table and columns it points at")
    func foreignKeyCaption() {
        var key = EditableForeignKeyDefinition.from(TestFixtures.makeForeignKeyInfo(referencedTable: "customers"))
        key.referencedColumns = ["id", "region"]

        #expect(TableDetailRowLogic.caption(for: .foreignKey(key)) == "\u{2192} customers(id, region)")
    }

    @Test("A check's caption is its expression on one line")
    func checkCaption() {
        let check = TableDetailItem.check(CheckConstraintInfo(name: "total_range", expression: "total > 0\n  AND\ttotal < 1000"))

        #expect(TableDetailRowLogic.caption(for: check) == "total > 0 AND total < 1000")
    }

    @Test("VoiceOver reads the kind, the name and the caption")
    func accessibilityLabels() {
        let column = TableDetailItem.column(TestFixtures.makeColumnInfo(name: "total", dataType: "numeric"))
        let label = TableDetailRowLogic.accessibilityLabel(for: column)

        #expect(label.contains("total"))
        #expect(label.contains("numeric"))
        #expect(label.contains(String(localized: "Column")))
        #expect(TableDetailRowLogic.groupAccessibilityLabel(kind: .columns, count: nil) == String(localized: "Columns"))
        #expect(
            TableDetailRowLogic.groupAccessibilityLabel(kind: .columns, count: 1)
                != TableDetailRowLogic.groupAccessibilityLabel(kind: .columns, count: 2)
        )
    }

    @Test("A trigger under its table captions when it fires; under a schema, its table")
    func triggerCaption() {
        let trigger = TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "", table: "orders")
        let bare = TriggerInfo(name: "audit", timing: "", event: "", statement: "")

        #expect(TriggerRowLogic.caption(for: trigger, listedUnderTable: true) == "AFTER INSERT")
        #expect(TriggerRowLogic.caption(for: trigger, listedUnderTable: false) == "orders")
        #expect(TriggerRowLogic.caption(for: bare, listedUnderTable: true) == nil)
        #expect(TriggerRowLogic.caption(for: bare, listedUnderTable: false) == nil)
    }
}
