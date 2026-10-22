//
//  AISchemaContextRelevanceTests.swift
//  TableProTests
//
//  A schema with more tables than the prompt's column budget spends that budget on the tables
//  the editor's query reads and the question names.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

struct AISchemaContextRelevanceTests {
    private static let tables: [TableInfo] = [
        TestFixtures.makeTableInfo(name: "audit_log"),
        TestFixtures.makeTableInfo(name: "customers"),
        TestFixtures.makeTableInfo(name: "invoices"),
        TableInfo(name: "tbl_x", type: .table, rowCount: 0, comment: "Monthly revenue snapshots"),
        TestFixtures.makeTableInfo(name: "orders")
    ]

    private static let grammar = DatabaseType.postgresql.lexicalGrammar

    private static func names(
        question: String,
        query: String = "",
        columns: [String: [ColumnInfo]] = [:],
        maxTables: Int = 2
    ) -> [String] {
        AISchemaContext.relevantTableNames(
            in: tables,
            columnsByTable: columns,
            question: question,
            queryReferences: AISchemaContext.referencedTables(in: query, grammar: grammar),
            maxTables: maxTables
        )
    }

    private static func everyTableColumns(_ extra: [String: [ColumnInfo]]) -> [String: [ColumnInfo]] {
        var columns = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, [TestFixtures.makeColumnInfo(name: "id")]) })
        columns.merge(extra) { _, new in new }
        return columns
    }

    @Test("Tables that match the question come first, best first")
    func matchingTablesComeFirst() {
        let names = Self.names(question: "How many orders did each customer place?")
        #expect(Array(names.prefix(2)).sorted() == ["customers", "orders"])
    }

    @Test("A table comment counts as a match")
    func commentMatches() {
        #expect(Self.names(question: "revenue by month").first == "tbl_x")
    }

    @Test("Columns count once every table has them")
    func columnsMatchWhenEveryTableHasThem() {
        let columns = Self.everyTableColumns(["invoices": [TestFixtures.makeColumnInfo(name: "due_date")]])
        #expect(Self.names(question: "unpaid past the due date", columns: columns).first == "invoices")
    }

    @Test("Columns loaded for some tables only do not count")
    func partialColumnsAreIgnored() {
        let columns = ["audit_log": [TestFixtures.makeColumnInfo(name: "customer_note")]]
        #expect(Self.names(question: "customer", columns: columns).first == "customers")
        #expect(!Self.names(question: "note", columns: columns).contains("audit_log"))
    }

    @Test("Nothing is reordered when every table fits")
    func everyTableFits() {
        #expect(Self.names(question: "orders", maxTables: Self.tables.count).isEmpty)
    }

    @Test("Tables the editor's query reads come before the question's matches")
    func queryTablesComeFirst() {
        let names = Self.names(
            question: "why is this slow for customers",
            query: "SELECT * FROM invoices i JOIN audit_log a ON a.id = i.id"
        )
        #expect(Array(names.prefix(3)) == ["invoices", "audit_log", "customers"])
    }

    @Test("SQL keywords in the editor's query match no table")
    func queryKeywordsMatchNothing() {
        let names = Self.names(
            question: "",
            query: "SELECT id FROM customers GROUP BY id ORDER BY id"
        )
        #expect(names == ["customers"])
    }

    @Test("Every statement in the editor counts, and a CTE name matches no table")
    func everyStatementCounts() {
        let query = """
        WITH recent AS (SELECT * FROM orders) SELECT * FROM recent;
        UPDATE customers SET name = 'x';
        """
        #expect(Self.names(question: "", query: query) == ["orders", "customers"])
    }

    @Test("A CTE named like a table puts that table first")
    func shadowingCommonTableExpression() {
        let query = "WITH orders AS (SELECT * FROM orders WHERE total > 0) SELECT * FROM orders"
        #expect(Self.names(question: "", query: query) == ["orders"])
    }

    @Test("A schema-qualified reference matches only a table in that schema")
    func schemaQualifiedReference() {
        let tables = [
            TestFixtures.makeTableInfo(name: "orders", schema: "archive"),
            TestFixtures.makeTableInfo(name: "orders", schema: "public")
        ]
        let references = AISchemaContext.referencedTables(in: "SELECT * FROM public.orders", grammar: Self.grammar)
        #expect(AISchemaContext.indices(of: references, in: tables) == [1])
    }

    @Test("A bare name puts the default schema's table first")
    func bareNameMeansDefaultSchema() {
        let tables = [
            TestFixtures.makeTableInfo(name: "orders", schema: "archive"),
            TestFixtures.makeTableInfo(name: "orders", schema: "public")
        ]
        let references = AISchemaContext.referencedTables(in: "SELECT * FROM orders", grammar: Self.grammar)
        #expect(AISchemaContext.indices(of: references, in: tables, defaultSchema: "public") == [1, 0])
    }

    @Test("A name that matches two tables by case puts both first")
    func caseCollisionKeepsBoth() {
        let tables = [
            TestFixtures.makeTableInfo(name: "audit_log", schema: "public"),
            TestFixtures.makeTableInfo(name: "Orders", schema: "public"),
            TestFixtures.makeTableInfo(name: "orders", schema: "public")
        ]
        for query in ["SELECT * FROM Orders", "SELECT * FROM \"orders\""] {
            let references = AISchemaContext.referencedTables(in: query, grammar: Self.grammar)
            #expect(Set(AISchemaContext.indices(of: references, in: tables, defaultSchema: "public")) == [1, 2])
        }
    }

    @Test("A qualified name leaves another schema's table out")
    func qualifiedNameStaysInItsSchema() {
        let tables = [
            TestFixtures.makeTableInfo(name: "orders", schema: "archive"),
            TestFixtures.makeTableInfo(name: "orders", schema: "public")
        ]
        let references = AISchemaContext.referencedTables(in: "ALTER TABLE archive.orders ADD due DATE", grammar: Self.grammar)
        #expect(AISchemaContext.indices(of: references, in: tables, defaultSchema: "public") == [0])
    }

    @Test("A query that ends in a comment still puts its tables first")
    func queryEndingInCommentCounts() {
        #expect(Self.names(question: "", query: "SELECT * FROM invoices -- unpaid ones") == ["invoices"])
    }

    @Test("Tables past the budget are counted, not named")
    func hiddenTablesAreCounted() {
        let section = AISchemaContext.buildSchemaSection(
            tables: Self.tables.map { AISchemaTable(table: $0) },
            defaultSchema: nil,
            maxTables: 2,
            identifierQuote: "\""
        )
        #expect(section.hasSuffix("… and 3 more tables (not shown)"))
        #expect(!section.contains("\"invoices\""))
    }
}
