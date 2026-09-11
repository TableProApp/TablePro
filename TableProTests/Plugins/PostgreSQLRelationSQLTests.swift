//
//  PostgreSQLRelationSQLTests.swift
//  TableProTests
//
//  Tests for PostgreSQLRelationSQL (compiled via project.yml from PostgreSQLDriverPlugin). The
//  expectations come from PostgreSQL 17.11: COMMENT ON checks its keyword against the relation's
//  relkind, and CONCURRENTLY is refused for a view with no usable unique index or no rows.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL relation statements")
struct PostgreSQLRelationSQLTests {
    // MARK: - Comments

    @Test("The COMMENT keyword follows the object kind", arguments: [
        ("TABLE", "TABLE"),
        ("PARTITIONED TABLE", "TABLE"),
        ("VIEW", "VIEW"),
        ("MATERIALIZED VIEW", "MATERIALIZED VIEW"),
        ("FOREIGN TABLE", "FOREIGN TABLE")
    ])
    func commentKeywordFollowsKind(objectType: String, keyword: String) {
        #expect(PostgreSQLRelationSQL.commentKeyword(forObjectType: objectType) == keyword)
    }

    /// `COMMENT ON TABLE` on a view fails with "is not a table", so a kind with no keyword of its
    /// own produces no statement rather than one the server refuses.
    @Test("A kind PostgreSQL cannot comment on produces no statement", arguments: [
        "SYSTEM TABLE", "EXTERNAL TABLE", "SEQUENCE", ""
    ])
    func unsupportedKindsProduceNoStatement(objectType: String) {
        #expect(PostgreSQLRelationSQL.commentKeyword(forObjectType: objectType) == nil)
        #expect(PostgreSQLRelationSQL.commentStatement(
            name: "t", schema: "s", objectType: objectType, comment: "x"
        ) == nil)
    }

    @Test("A comment statement qualifies and quotes the object")
    func commentStatementQualifies() {
        let sql = PostgreSQLRelationSQL.commentStatement(
            name: "Mat \"View\" X",
            schema: "My \"Odd\" Schema",
            objectType: "MATERIALIZED VIEW",
            comment: "it's here"
        )

        #expect(sql == "COMMENT ON MATERIALIZED VIEW \"My \"\"Odd\"\" Schema\".\"Mat \"\"View\"\" X\" IS 'it''s here'")
    }

    /// Quote doubling alone is injectable when `standard_conforming_strings` is off, where a
    /// trailing backslash eats the closing quote. A value holding one is written as an E'' string.
    @Test("A comment with a backslash is written as an E-string")
    func backslashCommentUsesEString() {
        let sql = PostgreSQLRelationSQL.commentStatement(
            name: "t", schema: "s", objectType: "TABLE", comment: #"Path C:\temp\"#
        )

        #expect(sql == #"COMMENT ON TABLE "s"."t" IS E'Path C:\\temp\\'"#)
    }

    @Test("An empty or missing comment clears it")
    func emptyCommentClears() {
        #expect(PostgreSQLRelationSQL.commentValue(nil) == "NULL")
        #expect(PostgreSQLRelationSQL.commentValue("") == "NULL")
        #expect(PostgreSQLRelationSQL.commentStatement(
            name: "t", schema: "s", objectType: "TABLE", comment: nil
        ) == "COMMENT ON TABLE \"s\".\"t\" IS NULL")
    }

    /// Whitespace is a value here. Deciding that a field holding only spaces means "remove the
    /// comment" belongs to the sheet, which normalizes before asking for a statement.
    @Test("Whitespace is quoted rather than treated as a clear")
    func whitespaceCommentIsStored() {
        #expect(PostgreSQLRelationSQL.commentValue("   ") == "'   '")
    }

    // MARK: - Refresh

    @Test("Refresh qualifies the view and adds CONCURRENTLY only when asked")
    func refreshStatementShape() {
        #expect(PostgreSQLRelationSQL.refreshStatement(name: "mv", schema: "sales", concurrently: false)
            == "REFRESH MATERIALIZED VIEW \"sales\".\"mv\"")
        #expect(PostgreSQLRelationSQL.refreshStatement(name: "mv", schema: "sales", concurrently: true)
            == "REFRESH MATERIALIZED VIEW CONCURRENTLY \"sales\".\"mv\"")
    }

    @Test("Refresh quotes a name that needs it")
    func refreshQuotesNames() {
        #expect(PostgreSQLRelationSQL.refreshStatement(
            name: "MV \"Totals\"", schema: "Sales Q1", concurrently: false
        ) == "REFRESH MATERIALIZED VIEW \"Sales Q1\".\"MV \"\"Totals\"\"\"")
    }

    /// The predicate measured against every index shape on PostgreSQL 17.11:
    /// `scripts/check-postgres-matview-refresh.sh` re-runs that comparison against a live server.
    @Test("The eligibility query tests exactly what the server requires")
    func eligibilityQueryPredicate() {
        let sql = PostgreSQLRelationSQL.concurrentRefreshQuery(name: "mv", schema: "sales")

        #expect(sql.contains("c.relispopulated"))
        #expect(sql.contains("i.indisunique"))
        #expect(sql.contains("i.indimmediate"))
        #expect(sql.contains("i.indisvalid"))
        #expect(sql.contains("i.indpred IS NULL"))
        #expect(sql.contains("i.indexprs IS NULL"))
        #expect(sql.contains("c.relkind = 'm'"))
        #expect(sql.contains("n.nspname = 'sales'"))
        #expect(sql.contains("c.relname = 'mv'"))
    }

    /// An unpopulated view is refused whatever its indexes are, and the fix for it is a plain
    /// refresh rather than a new index, so population is reported first.
    @Test("Population is reported before the index requirement")
    func populationTakesPrecedence() {
        #expect(PostgreSQLRelationSQL.concurrentRefreshAvailability(
            isPopulated: false, hasUsableUniqueIndex: true
        ) == .requiresPopulatedView)
        #expect(PostgreSQLRelationSQL.concurrentRefreshAvailability(
            isPopulated: false, hasUsableUniqueIndex: false
        ) == .requiresPopulatedView)
        #expect(PostgreSQLRelationSQL.concurrentRefreshAvailability(
            isPopulated: true, hasUsableUniqueIndex: false
        ) == .requiresUniqueIndex)
        #expect(PostgreSQLRelationSQL.concurrentRefreshAvailability(
            isPopulated: true, hasUsableUniqueIndex: true
        ) == .available)
    }
}
