import Foundation
@testable import TablePro
import Testing

struct CascadeDeleteSQLTests {
    static let dialect = CascadeSQLDialect(
        quote: { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" },
        qualifiedTable: { "\"public\".\"\($0)\"" },
        textLiteral: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
    )

    private static let customers = CascadeRowSet.keyed(table: "customers", columns: ["id"], values: [["1"], ["2"]])

    private static let orders = CascadeRowSet.referencing(
        table: "orders", columns: ["customer_id"], parentColumns: ["id"], parent: customers
    )

    private static func effect(_ table: String, _ kind: CascadeEffect.Kind = .delete, _ paths: [CascadeRowSet]) -> CascadeEffect {
        CascadeEffect(table: table, kind: kind, constraints: [], paths: paths, hasUnexpressiblePath: false)
    }

    @Test("A direct child selects through the parent's own column")
    func directChild() {
        let condition = CascadeDeleteSQL.condition(for: Self.effect("orders", [Self.orders]), dialect: Self.dialect)

        #expect(condition == #"EXISTS (SELECT 1 FROM "public"."customers" cascade_1 WHERE cascade_1."id" = "orders"."customer_id" AND (cascade_1."id" IN ('1', '2')))"#)
    }

    @Test("A grandchild nests one subquery per key")
    func grandchild() {
        let items = CascadeRowSet.referencing(
            table: "order_items", columns: ["order_id"], parentColumns: ["id"], parent: Self.orders
        )

        let condition = CascadeDeleteSQL.condition(for: Self.effect("order_items", [items]), dialect: Self.dialect)

        #expect(condition == #"EXISTS (SELECT 1 FROM "public"."orders" cascade_1 WHERE cascade_1."id" = "order_items"."order_id" AND ("#
            + #"EXISTS (SELECT 1 FROM "public"."customers" cascade_2 WHERE cascade_2."id" = cascade_1."customer_id" AND (cascade_2."id" IN ('1', '2')))))"#)
    }

    @Test("A composite key correlates on every column pair")
    func compositeKey() {
        let lines = CascadeRowSet.referencing(
            table: "order_lines",
            columns: ["order_no", "order_year"],
            parentColumns: ["no", "year"],
            parent: .keyed(table: "orders", columns: ["no", "year"], values: [["7", "2026"], ["8", "2026"]])
        )

        let condition = CascadeDeleteSQL.condition(for: Self.effect("order_lines", [lines]), dialect: Self.dialect)

        #expect(condition == #"EXISTS (SELECT 1 FROM "public"."orders" cascade_1 WHERE cascade_1."no" = "order_lines"."order_no" AND cascade_1."year" = "order_lines"."order_year" AND (("#
            + #"cascade_1."no" = '7' AND cascade_1."year" = '2026') OR (cascade_1."no" = '8' AND cascade_1."year" = '2026')))"#)
    }

    @Test("Two routes to one table are counted as their union")
    func unionOfPaths() {
        let tickets = CascadeRowSet.referencing(
            table: "notes", columns: ["ticket_id"], parentColumns: ["id"],
            parent: .keyed(table: "tickets", columns: ["id"], values: [["3"]])
        )
        let fromOrders = CascadeRowSet.referencing(
            table: "notes", columns: ["order_id"], parentColumns: ["id"],
            parent: .keyed(table: "orders", columns: ["id"], values: [["4"]])
        )

        let condition = CascadeDeleteSQL.condition(for: Self.effect("notes", [tickets, fromOrders]), dialect: Self.dialect)

        #expect(condition == #"(EXISTS (SELECT 1 FROM "public"."tickets" cascade_1 WHERE cascade_1."id" = "notes"."ticket_id" AND (cascade_1."id" IN ('3'))))"#
            + #" OR (EXISTS (SELECT 1 FROM "public"."orders" cascade_1 WHERE cascade_1."id" = "notes"."order_id" AND (cascade_1."id" IN ('4'))))"#)
    }

    @Test("Rows of the deleted table that are being deleted anyway are left out of its own count")
    func selfReferenceExcludesDeletedRows() {
        let deleted = CascadeRowSet.keyed(table: "employees", columns: ["id"], values: [["1"]])
        let reports = CascadeRowSet.referencing(
            table: "employees", columns: ["manager_id"], parentColumns: ["id"], parent: deleted
        )

        let condition = CascadeDeleteSQL.condition(for: Self.effect("employees", [reports]), excluding: [deleted], dialect: Self.dialect)

        #expect(condition == #"(EXISTS (SELECT 1 FROM "public"."employees" cascade_1 WHERE cascade_1."id" = "employees"."manager_id" AND (cascade_1."id" IN ('1'))))"#
            + #" AND CASE WHEN "employees"."id" IN ('1') THEN 1 ELSE 0 END = 0"#)
    }

    @Test("The deleted rows are not excluded from another table's count")
    func exclusionOnlyOnTheDeletedTable() {
        let condition = CascadeDeleteSQL.condition(for: Self.effect("orders", [Self.orders]), excluding: [Self.customers], dialect: Self.dialect)

        #expect(condition?.contains("CASE") == false)
    }

    @Test("A long key list is split into lists Oracle accepts")
    func longListIsChunked() {
        let values = (1...1_500).map { [String($0)] }
        let parent = CascadeRowSet.keyed(table: "customers", columns: ["id"], values: values)
        let child = CascadeRowSet.referencing(table: "orders", columns: ["customer_id"], parentColumns: ["id"], parent: parent)

        let condition = CascadeDeleteSQL.condition(for: Self.effect("orders", [child]), dialect: Self.dialect) ?? ""

        #expect(condition.components(separatedBy: "cascade_1.\"id\" IN (").count - 1 == 2)
        #expect(condition.contains("'1000')) OR (cascade_1.\"id\" IN ('1001'"))
    }

    @Test("Values go through the dialect's literal, quotes included")
    func valuesAreEscaped() {
        let parent = CascadeRowSet.keyed(table: "customers", columns: ["name"], values: [["O'Brien"]])
        let child = CascadeRowSet.referencing(table: "orders", columns: ["customer_name"], parentColumns: ["name"], parent: parent)

        let condition = CascadeDeleteSQL.condition(for: Self.effect("orders", [child]), dialect: Self.dialect)

        #expect(condition?.contains("'O''Brien'") == true)
    }

    @Test("An alias never takes the name of a table in the query")
    func aliasAvoidsTableNames() {
        #expect(CascadeDeleteSQL.aliasPrefix(avoiding: ["orders", "customers"]) == "cascade_")
        #expect(CascadeDeleteSQL.aliasPrefix(avoiding: ["Cascade_1"]) == "xcascade_")
    }

    @Test("An effect with a route SQL cannot express has no condition")
    func uncountableEffect() {
        let effect = CascadeEffect(table: "orders", kind: .delete, constraints: [], paths: [], hasUnexpressiblePath: true)

        #expect(CascadeDeleteSQL.condition(for: effect, dialect: Self.dialect) == nil)
    }

    @Test("The count reads the qualified table under the condition")
    func countQuery() {
        #expect(
            CascadeDeleteSQL.countQuery(table: "orders", condition: "x = 1", dialect: Self.dialect)
                == #"SELECT COUNT(*) FROM "public"."orders" WHERE x = 1"#
        )
    }
}
