//
//  PostgreSQLCommentStatementsTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("PostgreSQL comment statements")
struct PostgreSQLCommentStatementsTests {
    private func row(relkind: String, column: String?, description: String?) -> [String?] {
        [relkind, column, description]
    }

    @Test("The relation's own comment is rendered first, then its columns in row order")
    func relationCommentPrecedesColumns() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders",
            schema: "app",
            rows: [
                row(relkind: "r", column: nil, description: "Orders table"),
                row(relkind: "r", column: "id", description: "Primary key"),
                row(relkind: "r", column: "label", description: "Label")
            ])

        #expect(statements == [
            "COMMENT ON TABLE \"app\".\"orders\" IS 'Orders table'",
            "COMMENT ON COLUMN \"app\".\"orders\".\"id\" IS 'Primary key'",
            "COMMENT ON COLUMN \"app\".\"orders\".\"label\" IS 'Label'"
        ])
    }

    @Test("relkind picks the keyword, because the server refuses a mismatched one")
    func relkindPicksTheKeyword() {
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "r") == "TABLE")
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "p") == "TABLE")
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "f") == "FOREIGN TABLE")
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "v") == "VIEW")
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "m") == "MATERIALIZED VIEW")
        #expect(PostgreSQLRelationSQL.commentKeyword(forRelkind: "i") == nil)
    }

    @Test("A view, a materialized view and a foreign table each get their own keyword")
    func eachRelationKindRendersItsKeyword() {
        let view = PostgreSQLCommentStatements.statements(
            name: "v_orders", schema: "app",
            rows: [row(relkind: "v", column: nil, description: "View comment")])
        let matview = PostgreSQLCommentStatements.statements(
            name: "m_orders", schema: "app",
            rows: [row(relkind: "m", column: nil, description: "Matview comment")])
        let foreign = PostgreSQLCommentStatements.statements(
            name: "f_orders", schema: "app",
            rows: [row(relkind: "f", column: nil, description: "Foreign comment")])

        #expect(view == ["COMMENT ON VIEW \"app\".\"v_orders\" IS 'View comment'"])
        #expect(matview == ["COMMENT ON MATERIALIZED VIEW \"app\".\"m_orders\" IS 'Matview comment'"])
        #expect(foreign == ["COMMENT ON FOREIGN TABLE \"app\".\"f_orders\" IS 'Foreign comment'"])
    }

    @Test("A relkind with no COMMENT keyword yields no statement")
    func unknownRelkindYieldsNothing() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders_pkey", schema: "app",
            rows: [row(relkind: "i", column: nil, description: "Index comment")])

        #expect(statements.isEmpty)
    }

    @Test("A value holding a backslash and a quote renders the server's own quote_literal output")
    func backslashAndQuoteRenderAsEscapeString() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders", schema: "app",
            rows: [row(
                relkind: "r",
                column: "path",
                description: #"Windows path C:\temp and a quote ' here"#)])

        #expect(statements == [
            #"COMMENT ON COLUMN "app"."orders"."path" IS E'Windows path C:\\temp and a quote '' here'"#
        ])
    }

    @Test("A comment with a single quote and no backslash stays a plain literal")
    func singleQuoteDoublesInPlainLiteral() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders", schema: "app",
            rows: [row(relkind: "r", column: "label", description: "It's a label")])

        #expect(statements == ["COMMENT ON COLUMN \"app\".\"orders\".\"label\" IS 'It''s a label'"])
    }

    @Test("A multi-line comment stays inside one literal")
    func multiLineCommentStaysOneLiteral() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders", schema: "app",
            rows: [row(relkind: "r", column: "notes", description: "First line\nSecond line")])

        #expect(statements == [
            "COMMENT ON COLUMN \"app\".\"orders\".\"notes\" IS 'First line\nSecond line'"
        ])
    }

    @Test("A double quote in an identifier is doubled")
    func doubleQuoteInIdentifierIsDoubled() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "od\"d", schema: "sc\"h",
            rows: [row(relkind: "r", column: "co\"l", description: "Comment")])

        #expect(statements == ["COMMENT ON COLUMN \"sc\"\"h\".\"od\"\"d\".\"co\"\"l\" IS 'Comment'"])
    }

    @Test("A nil or empty description yields no statement, never IS NULL")
    func emptyDescriptionYieldsNothing() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders", schema: "app",
            rows: [
                row(relkind: "r", column: nil, description: nil),
                row(relkind: "r", column: "id", description: "")
            ])

        #expect(statements.isEmpty)
    }

    @Test("A short row is skipped rather than read past its end")
    func shortRowIsSkipped() {
        let statements = PostgreSQLCommentStatements.statements(
            name: "orders", schema: "app", rows: [["r", nil]])

        #expect(statements.isEmpty)
    }

    @Test("catalogQuery quotes both literals so a name holding a quote cannot end them")
    func catalogQueryQuotesItsLiterals() {
        let query = PostgreSQLCommentStatements.catalogQuery(name: "O'Brien", schema: "sa'les")

        #expect(query.contains("c.relname = 'O''Brien'"))
        #expect(query.contains("n.nspname = 'sa''les'"))
        #expect(!query.contains("'O'Brien'"))
    }

    @Test("catalogQuery reads only the relation kinds a COMMENT statement can name")
    func catalogQueryFiltersRelationKinds() {
        let query = PostgreSQLCommentStatements.catalogQuery(name: "orders", schema: "app")

        #expect(query.contains("c.relkind IN ('r', 'p', 'f', 'v', 'm')"))
    }

    @Test("catalogQuery excludes dropped and system columns and orders the relation before them")
    func catalogQueryExcludesDroppedColumns() {
        let query = PostgreSQLCommentStatements.catalogQuery(name: "orders", schema: "app")

        #expect(query.contains("NOT a.attisdropped"))
        #expect(query.contains("a.attnum > 0"))
        #expect(query.contains("ORDER BY ordinal, attnum"))
    }

    @Test("catalogQuery reads both description functions and drops a relation with neither")
    func catalogQueryReadsBothDescriptionFunctions() {
        let query = PostgreSQLCommentStatements.catalogQuery(name: "orders", schema: "app")

        #expect(query.contains("pg_catalog.obj_description(c.oid, 'pg_class') IS NOT NULL"))
        #expect(query.contains("pg_catalog.col_description(c.oid, a.attnum) IS NOT NULL"))
    }
}
