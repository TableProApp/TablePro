import Foundation
import Testing

@testable import TablePro

struct JoinQueryDraftTests {
    private let graph = JoinGraphTests.graph()

    private func draft(_ tables: [String]) -> JoinQueryDraft {
        var draft = JoinQueryDraft()
        for table in tables {
            draft.add(table, in: graph)
        }
        return draft
    }

    @Test("Picking orders then customers joins customers on the order's key")
    func secondTableTakesTheKey() {
        let draft = draft(["orders", "customers"])

        #expect(draft.tables.map { $0.name } == ["orders", "customers"])
        #expect(draft.tables[0].condition == nil)
        #expect(draft.tables[1].condition?.name == "orders_customer_fk")
        #expect(draft.tables[1].kind == .inner)
    }

    @Test("Picking a many-to-many pair brings in the junction between them")
    func junctionIsAdded() {
        let draft = draft(["orders", "products"])

        #expect(draft.tables.map { $0.name } == ["orders", "order_items", "products"])
        #expect(draft.tables[1].condition?.name == "items_order_fk")
        #expect(draft.tables[2].condition?.name == "items_product_fk")
    }

    @Test("A table no key reaches is added without a condition")
    func unlinkedTableIsCrossJoined() {
        let draft = draft(["orders", "notes"])

        #expect(draft.tables.map { $0.name } == ["orders", "notes"])
        #expect(draft.tables[1].condition == nil)
    }

    @Test("Removing the table a later one joined on relinks it to a remaining one, or cross joins it")
    func removeRelinks() {
        var linked = draft(["customers", "orders", "order_items"])
        linked.remove("orders", in: graph)
        #expect(linked.tables.map { $0.name } == ["customers", "order_items"])
        #expect(linked.tables[1].condition == nil)

        var restarted = draft(["orders", "customers"])
        restarted.remove("orders", in: graph)
        #expect(restarted.tables.map { $0.name } == ["customers"])
        #expect(restarted.tables[0].condition == nil)

        var relinked = draft(["orders", "order_items", "products"])
        relinked.add("customers", in: graph)
        relinked.remove("order_items", in: graph)
        #expect(relinked.tables.map { $0.name } == ["orders", "products", "customers"])
        #expect(relinked.tables[1].condition == nil)
        #expect(relinked.tables[2].condition?.name == "orders_customer_fk")
    }

    @Test("A cross join the user chose survives removing an unrelated table")
    func chosenCrossJoinSurvives() {
        var draft = draft(["orders", "customers"])
        draft.setCondition(nil, forTableAt: 1, in: graph)
        draft.add("notes", in: graph)

        draft.remove("notes", in: graph)

        #expect(draft.tables.map { $0.name } == ["orders", "customers"])
        #expect(draft.tables[1].condition == nil)
    }

    @Test("Removing a table drops the filters on its columns")
    func removeDropsFilters() {
        var draft = draft(["orders", "customers"])
        draft.filters = [
            JoinFilter(column: JoinColumnRef(table: "customers", column: "name"), value: "Ada"),
            JoinFilter(column: JoinColumnRef(table: "orders", column: "status"), value: "paid")
        ]

        draft.remove("customers", in: graph)

        #expect(draft.filters.map { $0.column.table } == ["orders"])
    }

    @Test("Only a key to an earlier table can be set as a condition")
    func conditionMustReachAnEarlierTable() throws {
        var draft = draft(["orders", "customers", "notes"])
        let key = try #require(graph.relationships(between: "orders", and: "customers").first)

        draft.setCondition(key, forTableAt: 2, in: graph)
        #expect(draft.tables[2].condition == nil)

        draft.setCondition(nil, forTableAt: 1, in: graph)
        #expect(draft.tables[1].condition == nil)
        draft.setCondition(key, forTableAt: 1, in: graph)
        #expect(draft.tables[1].condition == key)
        #expect(draft.candidates(forTableAt: 1, in: graph) == [key])
    }

    @Test("Selected columns keep the table's own order whatever order they were ticked in")
    func columnsKeepTableOrder() {
        var draft = draft(["orders"])

        draft.setSelected(true, column: JoinColumnRef(table: "orders", column: "status"), in: graph)
        draft.setSelected(true, column: JoinColumnRef(table: "orders", column: "id"), in: graph)
        #expect(draft.tables[0].selectedColumns == ["id", "status"])

        draft.setSelected(false, column: JoinColumnRef(table: "orders", column: "id"), in: graph)
        #expect(draft.tables[0].selectedColumns == ["status"])
        #expect(draft.isSelected(JoinColumnRef(table: "orders", column: "status")))
    }
}
