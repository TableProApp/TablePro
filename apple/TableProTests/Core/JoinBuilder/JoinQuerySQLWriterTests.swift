import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct JoinQuerySQLWriterTests {
    private static let ansi = SQLDialectDescriptor(
        identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit, paginationStyle: .limit
    )

    private static let backtick = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        booleanLiteralStyle: .numeric, likeEscapeStyle: .explicit, paginationStyle: .limit,
        requiresBackslashEscaping: true
    )

    private static let bracket = SQLDialectDescriptor(
        identifierQuote: "[", keywords: [], functions: [], dataTypes: [],
        booleanLiteralStyle: .numeric, likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch, autoLimitStyle: .top
    )

    private let graph = JoinGraphTests.graph()

    private static let columnTypes: [String: [String: ColumnType]] = [
        "orders": [
            "id": .integer(rawType: "int"),
            "customer_id": .integer(rawType: "int"),
            "status": .text(rawType: "varchar")
        ],
        "customers": ["id": .integer(rawType: "int"), "name": .text(rawType: "varchar")]
    ]

    private func writer(
        dialect: SQLDialectDescriptor = Self.ansi,
        databaseType: DatabaseType = .postgresql,
        schema: String? = nil
    ) -> JoinQuerySQLWriter {
        JoinQuerySQLWriter(
            graph: graph,
            columnTypes: Self.columnTypes,
            dialect: dialect,
            databaseType: databaseType,
            schema: schema,
            quote: quoteIdentifierFromDialect(dialect)
        )
    }

    private func draft(_ tables: [String]) -> JoinQueryDraft {
        var draft = JoinQueryDraft()
        for table in tables {
            draft.add(table, in: graph)
        }
        return draft
    }

    @Test("Picking orders and customers writes the join on the order's key")
    func doneCriterion() {
        let sql = writer().sql(for: draft(["orders", "customers"]))

        #expect(sql == """
            SELECT *
            FROM "orders"
            JOIN "customers" ON "orders"."customer_id" = "customers"."id"
            """)
    }

    @Test("Identifiers are quoted for the engine")
    func quotingFollowsTheDialect() {
        let mysql = writer(dialect: Self.backtick, databaseType: .mysql).sql(for: draft(["orders", "customers"]))
        let sqlServer = writer(dialect: Self.bracket, databaseType: .mssql).sql(for: draft(["orders", "customers"]))

        #expect(mysql?.contains("JOIN `customers` ON `orders`.`customer_id` = `customers`.`id`") == true)
        #expect(sqlServer?.contains("JOIN [customers] ON [orders].[customer_id] = [customers].[id]") == true)
    }

    @Test("A junction pair writes two joins, and a left join says so")
    func junctionAndLeftJoin() {
        var draft = draft(["orders", "products"])
        draft.setKind(.left, forTableAt: 2)

        let sql = writer().sql(for: draft)

        #expect(sql == """
            SELECT *
            FROM "orders"
            JOIN "order_items" ON "order_items"."order_id" = "orders"."id"
            LEFT JOIN "products" ON "order_items"."product_id" = "products"."id"
            """)
    }

    @Test("A table no key links is cross joined, whatever join type it was given")
    func crossJoin() {
        var draft = draft(["orders", "notes"])
        draft.setKind(.left, forTableAt: 1)

        #expect(writer().sql(for: draft)?.hasSuffix("\nCROSS JOIN \"notes\"") == true)
    }

    @Test("Chosen columns replace the star, each named with its table")
    func chosenColumns() {
        var draft = draft(["orders", "customers"])
        draft.setSelected(true, column: JoinColumnRef(table: "customers", column: "name"), in: graph)
        draft.setSelected(true, column: JoinColumnRef(table: "orders", column: "id"), in: graph)

        let sql = writer().sql(for: draft)

        #expect(sql?.hasPrefix("SELECT \"orders\".\"id\", \"customers\".\"name\"\nFROM") == true)
    }

    @Test("Filters are typed and escaped the way the filter bar writes them, and joined with AND")
    func filters() {
        var draft = draft(["orders", "customers"])
        draft.filters = [
            JoinFilter(column: JoinColumnRef(table: "customers", column: "name"), value: "O'Hara"),
            JoinFilter(column: JoinColumnRef(table: "orders", column: "id"), filterOperator: .greaterThan, value: "10"),
            JoinFilter(column: JoinColumnRef(table: "orders", column: "status"), value: "")
        ]

        let sql = writer().sql(for: draft)

        #expect(sql?.hasSuffix("\nWHERE \"customers\".\"name\" = 'O''Hara' AND \"orders\".\"id\" > 10") == true)
    }

    @Test("Tables are named in the builder's schema only when the tab would not resolve them there")
    func schemaQualification() {
        let sql = writer(schema: "sales").sql(for: draft(["orders", "customers"]))

        #expect(sql == """
            SELECT *
            FROM "sales"."orders"
            JOIN "sales"."customers" ON "orders"."customer_id" = "customers"."id"
            """)
    }

    @Test("Nothing picked writes nothing")
    func emptyDraft() {
        #expect(writer().sql(for: JoinQueryDraft()) == nil)
    }
}
