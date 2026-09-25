//
//  QueryContextRendererTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryContextRendererTests {
    private let orders = QueryContextTable(
        name: "orders",
        schema: "public",
        kind: .table,
        content: .described(QueryContextTableStructure(
            columns: [
                QueryContextColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
                QueryContextColumn(name: "note", dataType: "text", isNullable: true, isPrimaryKey: false, comment: "a|b\nc")
            ],
            indexes: [
                QueryContextIndex(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true),
                QueryContextIndex(
                    name: "orders_open_idx",
                    columns: ["created_at"],
                    isUnique: false,
                    isPrimary: false,
                    method: "BTREE",
                    predicate: "status = 'open'",
                    includedColumns: ["total"],
                    isValid: false
                )
            ],
            foreignKeys: [
                QueryContextForeignKey(
                    name: "orders_customer_fk",
                    columns: ["customer_id"],
                    referencedSchema: "public",
                    referencedTable: "customers",
                    referencedColumns: ["id"],
                    onDelete: "CASCADE"
                )
            ],
            approximateRowCount: 1_204_332
        ))
    )

    @Test("The header names the engine, version, database and schema")
    func header() {
        let text = QueryContextRenderer.render(QueryContextSnapshot(
            engineName: "PostgreSQL", serverVersion: "16.2", databaseName: "shop", schemaName: "public"
        ))
        #expect(text.contains("- Engine: PostgreSQL 16.2"))
        #expect(text.contains("- Database: shop"))
        #expect(text.contains("- Schema: public"))
    }

    @Test("A described table shows rows, columns, every index fact and its foreign keys")
    func describedTable() {
        let text = QueryContextRenderer.tableSection(orders)
        #expect(text.contains("### public.orders (~1,204,332 rows)"))
        #expect(text.contains("| id | bigint | no | PK |"))
        #expect(text.contains("a\\|b c"))
        #expect(text.contains("- orders_pkey (id) [primary]"))
        #expect(text.contains("- orders_open_idx (created_at) [btree, include total, invalid, not used by the planner] where status = 'open'"))
        #expect(text.contains("- (customer_id) -> public.customers(id) on delete cascade"))
    }

    @Test("An unreadable table says why instead of looking empty")
    func unavailableTable() {
        let table = QueryContextTable(
            name: "secrets", schema: nil, kind: nil, content: .unavailable(reason: "permission denied\nfor table secrets")
        )
        #expect(QueryContextRenderer.tableSection(table) == "### secrets\nStructure unavailable: permission denied for table secrets")
    }

    @Test("Unknown index state is stated rather than read as no indexes")
    func unknownIndexes() {
        let table = QueryContextTable(name: "t", schema: nil, kind: .view, content: .described(QueryContextTableStructure(
            columns: [QueryContextColumn(name: "id", dataType: "int", isNullable: false, isPrimaryKey: false)],
            indexesUnavailableReason: "timeout"
        )))
        let text = QueryContextRenderer.tableSection(table)
        #expect(text.hasPrefix("### t (view)"))
        #expect(text.contains("Indexes: unavailable (timeout)"))
    }

    @Test("Wide tables are cut at the column limit and say how many were left out")
    func columnLimit() {
        let columns = (1...5).map { QueryContextColumn(name: "c\($0)", dataType: "int", isNullable: true, isPrimaryKey: false) }
        let text = QueryContextRenderer.columnTable(columns, limit: 3)
        #expect(text.contains("| c3 |"))
        #expect(!text.contains("| c4 |"))
        #expect(text.contains("… and 2 more columns not listed."))
    }

    @Test("Missing, foreign and overflow tables are listed by name")
    func gaps() {
        let text = QueryContextRenderer.render(QueryContextSnapshot(
            engineName: "MySQL",
            databaseName: "shop",
            tables: [orders],
            notFound: ["ghost"],
            outsideScope: ["archive.orders"],
            notDescribed: ["t13"]
        ))
        #expect(text.contains("- Not found in shop: ghost"))
        #expect(text.contains("- In another database, not described: archive.orders"))
        #expect(text.contains("over the limit of \(QueryContextBuilder.tableLimit) tables: t13"))
    }

    @Test("Tables past the size budget are named instead of sent, but the first is always sent")
    func characterBudget() {
        let second = QueryContextTable(name: "customers", schema: "public", kind: .table, content: .unavailable(reason: "x"))
        let text = QueryContextRenderer.render(
            QueryContextSnapshot(engineName: "PostgreSQL", tables: [orders, second]),
            characterBudget: 10
        )
        #expect(text.contains("### public.orders"))
        #expect(!text.contains("### public.customers"))
        #expect(text.contains("- Not described, too large to send in full: public.customers"))
    }

    @Test("An empty snapshot tells the model not to guess columns")
    func emptySnapshot() {
        let text = QueryContextRenderer.render(QueryContextSnapshot(engineName: "SQLite"))
        #expect(text.contains("No table structure could be read"))
    }

    @Test("A plan containing a fence cannot close the plan block early")
    func planIsFenceSafe() {
        let plan = "Seq Scan\n```\nfake end"
        let text = QueryContextRenderer.render(QueryContextSnapshot(engineName: "PostgreSQL", explainPlan: plan))
        #expect(text.contains("````text\n\(plan)\n````"))
    }
}

struct MarkdownFenceTests {
    @Test("Plain text gets a three-backtick fence")
    func plainFence() {
        #expect(MarkdownFence.wrap("SELECT 1", language: "sql") == "```sql\nSELECT 1\n```")
    }

    @Test("The fence is always longer than any backtick run inside the text")
    func longerFence() {
        let text = "SELECT '````' AS x"
        #expect(MarkdownFence.longestBacktickRun(in: text) == 4)
        #expect(MarkdownFence.wrap(text).hasPrefix("`````\n"))
    }

    @Test("A table cell escapes pipes and flattens newlines")
    func tableCell() {
        #expect(MarkdownFence.tableCell("a|b\r\nc") == "a\\|b c")
        #expect(MarkdownFence.tableCell(nil) == "")
    }
}
