import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLJoinConditionCompletionTests {
    private static func key(
        _ name: String, _ columns: [String], _ table: String, _ referenced: [String], schema: String? = nil
    ) -> SQLCompletionForeignKey {
        SQLCompletionForeignKey(
            name: name, columns: columns, referencedTable: table, referencedSchema: schema, referencedColumns: referenced
        )
    }

    // A fresh catalog per use, so one test's key reads never show in another's.
    private static var shop: StubCatalog {
        StubCatalog(
            tables: ["orders", "customers", "order_items", "payments", "flights", "airports", "employees"],
            columns: [
                "orders": ["id", "customer_id", "tenant_id", "total"],
                "customers": ["id", "name"],
                "order_items": ["order_id", "tenant_id", "qty"],
                "payments": ["id", "order_id", "customer_id"],
                "flights": ["id", "origin", "destination"],
                "airports": ["code", "name"],
                "employees": ["id", "manager_id"],
            ],
            keys: [
                "orders": [key("orders_customer_fk", ["customer_id"], "customers", ["id"])],
                "order_items": [key("items_order_fk", ["order_id", "tenant_id"], "orders", ["id", "tenant_id"])],
                "payments": [
                    key("payments_order_fk", ["order_id"], "orders", ["id"]),
                    key("payments_customer_fk", ["customer_id"], "customers", ["id"]),
                ],
                "flights": [
                    key("flights_origin_fk", ["origin"], "airports", ["code"]),
                    key("flights_destination_fk", ["destination"], "airports", ["code"]),
                ],
                "employees": [key("employees_manager_fk", ["manager_id"], "employees", ["id"])],
            ]
        )
    }

    // `|` marks the cursor.
    private func items(_ marked: String, catalog: StubCatalog? = nil) async -> [SQLCompletionItem] {
        let provider = SQLCompletionProvider(catalog: catalog ?? Self.shop, grammar: .engine("SQLite"), vocabulary: .generic)
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return await provider.completionSession(text: text, cursorPosition: marker.location).items
    }

    private func conditions(_ marked: String, catalog: StubCatalog? = nil) async -> [String] {
        await items(marked, catalog: catalog).filter { $0.kind == .joinCondition }.map(\.label)
    }

    @Test("Right after a join's ON the condition from the foreign key leads, the earlier table first")
    func conditionLeads() async {
        let first = await items("SELECT * FROM orders o JOIN customers c ON |").first
        #expect(first?.label == "o.customer_id = c.id")
        #expect(first?.insertText == "o.customer_id = c.id")
        #expect(first?.kind == .joinCondition)
        #expect(first?.detail == "orders_customer_fk")
    }

    @Test("A key from the joined table to an earlier one is written with the earlier table first too")
    func reverseDirection() async {
        #expect(await items("SELECT * FROM customers c JOIN orders o ON |").first?.label == "c.id = o.customer_id")
    }

    @Test("A table with no alias is named as written")
    func noAlias() async {
        #expect(await items("SELECT * FROM orders JOIN customers ON |").first?.label == "orders.customer_id = customers.id")
    }

    @Test("A composite key joins its pairs with AND in key order")
    func compositeKey() async {
        #expect(await items("SELECT * FROM orders o JOIN order_items i ON |").first?.label
            == "o.id = i.order_id AND o.tenant_id = i.tenant_id")
    }

    @Test("Two keys between one pair give one condition each")
    func twoKeys() async {
        #expect(await conditions("SELECT * FROM flights f JOIN airports a ON |")
            == ["f.origin = a.code", "f.destination = a.code"])
    }

    @Test("A self-join offers the key both ways")
    func selfJoin() async {
        #expect(await conditions("SELECT * FROM employees e JOIN employees m ON |")
            == ["e.manager_id = m.id", "e.id = m.manager_id"])
    }

    @Test("Earlier tables are paired nearest first")
    func nearestFirst() async {
        let marked = "SELECT * FROM customers c JOIN orders o ON o.customer_id = c.id JOIN payments p ON |"
        #expect(await conditions(marked) == ["o.id = p.order_id", "c.id = p.customer_id"])
    }

    @Test("A table joined after the cursor is neither paired nor read")
    func laterTableIsNotRead() async {
        let catalog = Self.shop
        let marked = "SELECT * FROM orders o JOIN customers c ON | JOIN payments p ON p.order_id = o.id"
        #expect(await conditions(marked, catalog: catalog) == ["o.customer_id = c.id"])
        #expect(catalog.keyReads.all.sorted() == ["customers", "orders"])
    }

    @Test("Typing the earlier alias keeps the condition first")
    func qualifierPrefix() async {
        #expect(await items("SELECT * FROM orders o JOIN customers c ON o|").first?.label == "o.customer_id = c.id")
    }

    @Test("No condition and no key read where the ON belongs to no join or the condition has started", arguments: [
        "CREATE INDEX idx ON |",
        "SELECT * FROM orders o JOIN customers c ON o.|",
        "SELECT * FROM orders o JOIN customers c ON \"|",
        "SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id AND |",
        "SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id |",
        "SELECT * FROM orders o JOIN (SELECT * FROM customers) c ON |",
        "WITH customers AS (SELECT 1 AS id) SELECT * FROM orders o JOIN customers c ON |",
        "SELECT * FROM orders o WHERE |",
    ])
    func noCondition(_ marked: String) async {
        let catalog = Self.shop
        #expect(await conditions(marked, catalog: catalog).isEmpty)
        #expect(catalog.keyReads.all.isEmpty)
    }

    @Test("A catalog that writes its own names quotes each side, and the label stays plain")
    func catalogWrittenCondition() async throws {
        var catalog = StubCatalog(
            tables: ["orders", "customers"],
            columns: ["orders": ["Id", "CustomerId"], "customers": ["Id"]],
            keys: ["orders": [Self.key("fk", ["CustomerId"], "customers", ["Id"])]]
        )
        catalog.writesNames = true
        let first = try #require(await items("SELECT * FROM orders \"O\" JOIN customers c ON |", catalog: catalog).first)
        #expect(first.label == "O.CustomerId = c.Id")
        #expect(first.insertText == "\"O\".\"CustomerId\" = c.\"Id\"")
    }

    @Test("A key column spelled in another case takes the table's spelling")
    func keyColumnTakesTableSpelling() async {
        let catalog = StubCatalog(
            tables: ["orders", "customers"],
            columns: ["orders": ["id", "customer_id"], "customers": ["id"]],
            keys: ["orders": [Self.key("fk", ["CUSTOMER_ID"], "Customers", ["ID"])]]
        )
        #expect(await conditions("SELECT * FROM orders o JOIN customers c ON |", catalog: catalog) == ["o.customer_id = c.id"])
    }

    // MARK: - The qualified columns of the same ON

    @Test("A column the catalog already qualifies is offered once, with the catalog's spelling")
    func qualifiedColumnOnce() async throws {
        var catalog = StubCatalog(tables: ["orders", "customers"], columns: ["orders": ["Id", "total"], "customers": ["Id"]])
        catalog.qualifiesInScope = true
        catalog.writesNames = true
        let items = await items("SELECT * FROM orders o JOIN customers c ON |", catalog: catalog)

        #expect(items.filter { $0.label == "o.Id" }.count == 1)
        let column = try #require(items.first { $0.label == "o.Id" })
        #expect(column.insertText == "o.\"Id\"")
        #expect(column.isQualifiedReference)
        #expect(column.sortPriority == 80)
    }

    @Test("A qualified column the catalog writes keeps a quoted alias and the column's quotes")
    func writtenQualifiedColumn() async {
        var catalog = StubCatalog(tables: ["orders"], columns: ["orders": ["Id"]])
        catalog.writesNames = true
        let items = await items("SELECT * FROM orders \"O\" ON |", catalog: catalog)
        #expect(items.first { $0.label == "O.Id" }?.insertText == "\"O\".\"Id\"")
    }

    // MARK: - Pairing

    private func side(_ table: String, alias: String, schema: String? = nil, keys: [SQLCompletionForeignKey] = []) -> SQLJoinConditions.Side {
        SQLJoinConditions.Side(
            reference: TableReference(tableName: table, alias: alias, schema: schema),
            keys: keys,
            columns: []
        )
    }

    @Test("Keys keep the driver's order, an earlier table's own keys before the joined table's")
    func pairingOrder() {
        let joined = side("airports", alias: "a", keys: [Self.key("hub_fk", ["hub_flight"], "flights", ["id"])])
        let earlier = side("flights", alias: "f", keys: [
            Self.key("destination_fk", ["destination"], "airports", ["code"]),
            Self.key("origin_fk", ["origin"], "airports", ["code"]),
        ])
        let names = SQLJoinConditions.conditions(joined: joined, earlier: [earlier]).map(\.constraintName)
        #expect(names == ["destination_fk", "origin_fk", "hub_fk"])
    }

    @Test("A key into another schema pairs only with a table of that schema")
    func pairingSchema() {
        let toSales = Self.key("fk", ["customer_id"], "customers", ["id"], schema: "sales")
        let orders = side("orders", alias: "o", keys: [toSales])
        #expect(SQLJoinConditions.conditions(joined: side("customers", alias: "c", schema: "sales"), earlier: [orders]).count == 1)
        #expect(SQLJoinConditions.conditions(joined: side("customers", alias: "c", schema: "public"), earlier: [orders]).isEmpty)
        #expect(SQLJoinConditions.conditions(joined: side("customers", alias: "c"), earlier: [orders]).count == 1)

        let salesOrders = side("orders", alias: "o", schema: "sales", keys: [toSales])
        #expect(SQLJoinConditions.conditions(joined: side("customers", alias: "c"), earlier: [salesOrders]).isEmpty)
        let ownNamespace = Self.key("fk", ["user_id"], "users", ["id"])
        let otherOrders = side("orders", alias: "o", schema: "otherdb", keys: [ownNamespace])
        #expect(SQLJoinConditions.conditions(joined: side("users", alias: "u"), earlier: [otherOrders]).isEmpty)
        #expect(SQLJoinConditions.conditions(joined: side("users", alias: "u", schema: "otherdb"), earlier: [otherOrders]).count == 1)
        let localOrders = side("orders", alias: "o", keys: [ownNamespace])
        #expect(SQLJoinConditions.conditions(joined: side("users", alias: "u", schema: "otherdb"), earlier: [localOrders]).isEmpty)
    }

    @Test("Driver rows group into one key per name and target, pairs in key order")
    func grouping() {
        let rows = [
            SQLCompletionForeignKey.Row(name: "items_fk", column: "order_id", referencedTable: "orders", referencedSchema: nil, referencedColumn: "id"),
            SQLCompletionForeignKey.Row(name: "origin_fk", column: "origin", referencedTable: "airports", referencedSchema: nil, referencedColumn: "code"),
            SQLCompletionForeignKey.Row(name: "items_fk", column: "tenant_id", referencedTable: "orders", referencedSchema: nil, referencedColumn: "tenant_id"),
            SQLCompletionForeignKey.Row(name: "items_fk", column: "tenant_id", referencedTable: "orders", referencedSchema: nil, referencedColumn: "tenant_id"),
            SQLCompletionForeignKey.Row(name: "destination_fk", column: "destination", referencedTable: "airports", referencedSchema: nil, referencedColumn: "code"),
        ]
        let keys = SQLCompletionForeignKey.grouping(rows)
        #expect(keys.map(\.name) == ["items_fk", "origin_fk", "destination_fk"])
        #expect(keys.first?.columns == ["order_id", "tenant_id"])
        #expect(keys.first?.referencedColumns == ["id", "tenant_id"])
    }
}
