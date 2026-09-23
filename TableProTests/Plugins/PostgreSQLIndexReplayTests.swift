//
//  PostgreSQLIndexReplayTests.swift
//  TableProTests
//
//  The PostgreSQL index read and the `CREATE INDEX` a copy writes back from it. The rows below are
//  the ones PostgreSQL 17.11 returned for these queries on a probe schema.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL index key parts")
struct PostgreSQLIndexKeyPartTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let beforeCoveringIndexes = PostgreSQLCapabilities(serverVersion: 100_021)
    private static let legacy = PostgreSQLCapabilities(serverVersion: 90_124)

    private static func row(
        table: String = "users",
        name: String,
        columns: String,
        unique: Bool = false,
        type: String = "btree",
        predicate: String? = nil,
        expressions: String = "{}",
        included: String = "{}",
        valid: String = "t"
    ) -> [PluginCellValue] {
        [
            .text(table), .text(name), .text(columns), .text(unique ? "true" : "false"), .text("false"),
            .text(type), predicate.map(PluginCellValue.text) ?? .null, .text(expressions), .text(included),
            .text(valid)
        ]
    }

    @Test("Validity is read with the rule a dump applies, so an index on a partitioned table counts as valid")
    func validityUsesTheDumpRule() {
        for table in ["users", nil] {
            let sql = PostgreSQLIndexQueries.indexList(schema: "public", table: table, capabilities: Self.modern)
            #expect(sql.contains("((ix.indisvalid OR t.relkind = 'p') AND ix.indisready) AS is_valid"))
            #expect(sql.contains("JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid"))
        }
    }

    @Test("An invalid index decodes as invalid and a valid one as valid")
    func validityIsDecoded() throws {
        let invalid = try #require(PostgreSQLIndexRow.index(
            from: Self.row(name: "users_email_key", columns: "{email}", unique: true, valid: "f"), ddl: [:]
        ))
        let valid = try #require(PostgreSQLIndexRow.index(
            from: Self.row(name: "users_email", columns: "{email}"), ddl: [:]
        ))
        #expect(invalid.index.isValid == false)
        #expect(valid.index.isValid == true)
    }

    @Test("A row with no validity column reports none")
    func missingValidityIsNotReported() throws {
        let decoded = try #require(PostgreSQLIndexRow.index(
            from: Array(Self.row(name: "users_email", columns: "{email}").prefix(9)), ddl: [:]
        ))
        #expect(decoded.index.isValid == nil)
    }

    @Test("Key parts stop at indnkeyatts from PostgreSQL 11, so INCLUDE columns are read separately")
    func keyCountFollowsCoveringIndexes() {
        let modern = PostgreSQLIndexQueries.indexList(schema: "public", table: nil, capabilities: Self.modern)
        #expect(modern.contains("generate_series(1, ix.indnkeyatts)"))
        #expect(modern.contains("generate_series(ix.indnkeyatts + 1, ix.indnatts)"))

        for capabilities in [Self.beforeCoveringIndexes, Self.legacy] {
            let older = PostgreSQLIndexQueries.indexList(schema: "public", table: nil, capabilities: capabilities)
            #expect(!older.contains("indnkeyatts"))
            #expect(older.contains("generate_series(1, ix.indnatts)"))
        }
    }

    @Test("A key mixing a column and an expression keeps both, in key order")
    func mixedKeyKeepsItsExpression() throws {
        let decoded = try #require(PostgreSQLIndexRow.index(
            from: Self.row(
                name: "users_tenant_lower_email", columns: "{tenant_id,lower(email)}", unique: true,
                expressions: "{lower(email)}"
            ),
            ddl: [:]
        ))
        #expect(decoded.index.columns == ["tenant_id", "lower(email)"])
        #expect(decoded.index.expressions == ["lower(email)"])
        #expect(decoded.index.includedColumns == nil)
        #expect(decoded.index.isUnique)
    }

    @Test("An index over expressions alone is listed with every expression")
    func expressionOnlyIndexIsListed() throws {
        let decoded = try #require(PostgreSQLIndexRow.index(
            from: Self.row(
                name: "users_only_expr", columns: #"{lower(name),"(score + 1)"}"#,
                expressions: #"{lower(name),"(score + 1)"}"#
            ),
            ddl: [:]
        ))
        #expect(decoded.index.columns == ["lower(name)", "(score + 1)"])
        #expect(decoded.index.expressions == ["lower(name)", "(score + 1)"])
    }

    @Test("INCLUDE columns are their own field and not key parts")
    func includedColumnsAreNotKeys() throws {
        let decoded = try #require(PostgreSQLIndexRow.index(
            from: Self.row(name: "users_include", columns: "{tenant_id}", included: #"{name,"Weird Col"}"#),
            ddl: [:]
        ))
        #expect(decoded.index.columns == ["tenant_id"])
        #expect(decoded.index.includedColumns == ["name", "Weird Col"])
        #expect(decoded.index.expressions == nil)
    }

    @Test("An empty array reads as no expressions and no INCLUDE columns")
    func emptyArraysReadAsNil() throws {
        let decoded = try #require(PostgreSQLIndexRow.index(
            from: Self.row(name: "users_bloom", columns: "{b1,b2}", type: "bloom"),
            ddl: [:]
        ))
        #expect(decoded.index.expressions == nil)
        #expect(decoded.index.includedColumns == nil)
        #expect(decoded.index.type == "BLOOM")
        #expect(decoded.index.ddlMethodAndKeys == nil)
        #expect(decoded.index.ddlWhereClause == nil)
    }

    @Test("An index takes the DDL spellings of its own table and name, matched exactly")
    func spellingsAreMatchedByExactName() throws {
        let ddl = PostgreSQLIndexQueries.indexDDL(rows: [
            [.text("Orders"), .text("orders_a"), .text("USING hash (a)"), .null],
            [.text("orders"), .text("orders_a"), .text("USING btree (a)"), .null]
        ])
        let lower = try #require(PostgreSQLIndexRow.index(
            from: Self.row(table: "orders", name: "orders_a", columns: "{a}"), ddl: ddl
        ))
        let upper = try #require(PostgreSQLIndexRow.index(
            from: Self.row(table: "Orders", name: "orders_a", columns: "{a}", type: "hash"), ddl: ddl
        ))
        #expect(lower.index.ddlMethodAndKeys == "USING btree (a)")
        #expect(upper.index.ddlMethodAndKeys == "USING hash (a)")
        #expect(PostgreSQLIndexRow.index(
            from: Self.row(table: "orders", name: "Orders_a", columns: "{a}"), ddl: ddl
        )?.index.ddlMethodAndKeys == nil)
    }
}

@Suite("PostgreSQL index DDL spelling read")
struct PostgreSQLIndexDDLQueryTests {
    @Test("The prefix is built on the server with quote_ident, the way pg_get_indexdef quotes")
    func prefixUsesQuoteIdent() {
        let sql = PostgreSQLIndexQueries.indexDDLQuery(schema: "src", table: "users")
        #expect(sql.contains("pg_catalog.pg_get_indexdef(ix.indexrelid) AS definition"))
        #expect(sql.contains("CASE WHEN ix.indisunique THEN 'UNIQUE ' ELSE '' END"))
        #expect(sql.contains("|| 'INDEX ' || pg_catalog.quote_ident(i.relname) || ' ON '"))
        #expect(sql.contains(
            "|| pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(t.relname) || ' '"
        ))
    }

    /// Measured: an index created on a partitioned table without `ONLY` is still printed `ON ONLY`
    /// while it has no parent, and a partition's own index, which has one, is not.
    @Test("ONLY is expected for a partitioned index with no parent")
    func onlyForAParentlessPartitionedIndex() {
        let sql = PostgreSQLIndexQueries.indexDDLQuery(schema: "src", table: nil)
        #expect(sql.contains("WHEN i.relkind = 'I' AND NOT EXISTS ("))
        #expect(sql.contains("SELECT 1 FROM pg_catalog.pg_inherits inh WHERE inh.inhrelid = ix.indexrelid"))
        #expect(sql.contains(") THEN 'ONLY '"))
    }

    @Test("The suffix is the predicate as pg_get_expr writes it, and the keys are cut only when both ends match")
    func suffixAndCut() throws {
        let sql = PostgreSQLIndexQueries.indexDDLQuery(schema: "src", table: nil)
        #expect(sql.contains("COALESCE(' WHERE ' || pg_catalog.pg_get_expr(ix.indpred, ix.indrelid), '') AS suffix"))
        #expect(sql.contains("AND pg_catalog.substr(d.definition, 1, pg_catalog.length(d.prefix)) = d.prefix"))
        #expect(sql.contains(") = d.suffix"))
        let cutStart = try #require(sql.range(of: "CASE"))
        let cutEnd = try #require(sql.range(of: "END AS method_and_keys"))
        let cut = sql[cutStart.upperBound..<cutEnd.lowerBound]
        #expect(!cut.contains("ELSE"), "A mismatch has to leave method_and_keys NULL")
    }

    @Test("The per-table read adds one predicate to the whole-schema read")
    func perTableAddsOnePredicate() {
        let single = PostgreSQLIndexQueries.indexDDLQuery(schema: "src", table: "users")
        let bulk = PostgreSQLIndexQueries.indexDDLQuery(schema: "src", table: nil)
        #expect(single.contains("WHERE n.nspname = 'src' AND t.relname = 'users'"))
        #expect(!bulk.contains("t.relname ="))
    }

    @Test("A definition whose ends did not match keeps its predicate spelling and has no key spelling")
    func unmatchedDefinitionKeepsItsPredicate() throws {
        let ddl = PostgreSQLIndexQueries.indexDDL(rows: [
            [.text("users"), .text("users_partial_mood"), .null, .text("(m = 'a'::src.mood)")]
        ])
        let spelling = try #require(ddl["users"]?["users_partial_mood"])
        #expect(spelling.methodAndKeys == nil)
        #expect(spelling.whereClause == "(m = 'a'::src.mood)")
    }

    @Test("A row with no table or index name is skipped")
    func incompleteRowIsSkipped() {
        let ddl = PostgreSQLIndexQueries.indexDDL(rows: [[.null, .text("x"), .text("USING btree (a)"), .null]])
        #expect(ddl.isEmpty)
    }
}

@Suite("PostgreSQL index clauses")
struct PostgreSQLIndexClausesTests {
    private static let table = #""dst"."users""#

    private static func index(
        name: String = "ix",
        columns: [String],
        unique: Bool = false,
        type: String? = "BTREE",
        whereClause: String? = nil,
        expressions: [String]? = nil,
        includedColumns: [String]? = nil,
        ddlMethodAndKeys: String? = nil,
        ddlWhereClause: String? = nil
    ) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: name,
            columns: columns,
            isUnique: unique,
            indexType: type,
            whereClause: whereClause,
            expressions: expressions,
            includedColumns: includedColumns,
            ddlMethodAndKeys: ddlMethodAndKeys,
            ddlWhereClause: ddlWhereClause
        )
    }

    /// Replayed under `search_path = dst`, this recreated the source index exactly. The field-built
    /// statement failed with "data type text has no default operator class for access method gin"
    /// and "type mood does not exist".
    @Test("The server's spellings are written verbatim over the fields")
    func spellingsWinOverFields() {
        let sql = PostgreSQLIndexClauses.createStatement(
            for: Self.index(
                name: "users_email_trgm",
                columns: ["email"],
                type: "GIN",
                whereClause: "(m = 'a'::mood)",
                ddlMethodAndKeys: "USING gin (email public.gin_trgm_ops)",
                ddlWhereClause: "(m = 'a'::src.mood)"
            ),
            qualifiedTable: Self.table
        )
        #expect(sql == #"CREATE INDEX "users_email_trgm" ON "dst"."users" USING gin (email public.gin_trgm_ops) WHERE (m = 'a'::src.mood)"#)
    }

    @Test("A unique expression index keeps UNIQUE and its expression")
    func uniqueExpressionIndex() {
        let sql = PostgreSQLIndexClauses.createStatement(
            for: Self.index(
                name: "users_tenant_lower_email",
                columns: ["tenant_id", "lower(email)"],
                unique: true,
                expressions: ["lower(email)"],
                ddlMethodAndKeys: "USING btree (tenant_id, lower(email))"
            ),
            qualifiedTable: Self.table
        )
        #expect(sql == #"CREATE UNIQUE INDEX "users_tenant_lower_email" ON "dst"."users" USING btree (tenant_id, lower(email))"#)
    }

    /// The fallback shape, measured on PostgreSQL 17.11: it creates an index whose
    /// `pg_get_indexdef` reads `USING btree (tenant_id, lower(email), ((score + 1))) INCLUDE (name, "Weird Col")`.
    @Test("From the fields, expressions are parenthesised, columns quoted and INCLUDE written")
    func fieldsWriteExpressionsAndInclude() {
        let sql = PostgreSQLIndexClauses.createStatement(
            for: Self.index(
                name: "fallback_expr",
                columns: ["tenant_id", "lower(email)", "(score + 1)"],
                expressions: ["lower(email)", "(score + 1)"],
                includedColumns: ["name", "Weird Col"]
            ),
            qualifiedTable: Self.table
        )
        #expect(sql == #"CREATE INDEX "fallback_expr" ON "dst"."users" USING btree ("tenant_id", (lower(email)), ((score + 1))) INCLUDE ("name", "Weird Col")"#)
    }

    @Test("A plain index from the fields is written exactly as before")
    func plainIndexIsUnchanged() {
        #expect(
            PostgreSQLIndexClauses.createStatement(
                for: Self.index(columns: ["a", "b"], type: "HASH", whereClause: "(a > 0)"),
                qualifiedTable: Self.table
            ) == #"CREATE INDEX "ix" ON "dst"."users" USING hash ("a", "b") WHERE (a > 0)"#
        )
        #expect(
            PostgreSQLIndexClauses.createStatement(
                for: Self.index(columns: ["a"], type: nil),
                qualifiedTable: Self.table
            ) == #"CREATE INDEX "ix" ON "dst"."users" ("a")"#
        )
    }

    @Test("A predicate spelling applies without a key spelling")
    func predicateSpellingAlone() {
        let sql = PostgreSQLIndexClauses.createStatement(
            for: Self.index(
                columns: ["id"],
                whereClause: "st_isvalid(shape)",
                ddlWhereClause: "public.st_isvalid(shape)"
            ),
            qualifiedTable: Self.table
        )
        #expect(sql == #"CREATE INDEX "ix" ON "dst"."users" USING btree ("id") WHERE public.st_isvalid(shape)"#)
    }

    @Test("Empty spellings fall back to the fields")
    func emptySpellingsFallBack() {
        let index = Self.index(columns: ["a"], whereClause: "(a > 0)", ddlMethodAndKeys: "", ddlWhereClause: "")
        #expect(PostgreSQLIndexClauses.methodAndKeys(for: index) == #"USING btree ("a")"#)
        #expect(PostgreSQLIndexClauses.whereClause(for: index) == "(a > 0)")
    }

    @Test("INCLUDE columns are refused before PostgreSQL 11 and accepted from it")
    func includeNeedsPostgreSQL11() {
        let covering = Self.index(columns: ["a"], includedColumns: ["b"])
        let refused = PostgreSQLVersionedStatements.refusal(
            for: .addIndex(covering), capabilities: PostgreSQLCapabilities(serverVersion: 100_021)
        )
        #expect(refused == "INCLUDE columns need PostgreSQL 11 or later.")
        #expect(PostgreSQLVersionedStatements.refusal(
            for: .addIndex(covering), capabilities: PostgreSQLCapabilities(serverVersion: 110_000)
        ) == nil)
        #expect(PostgreSQLVersionedStatements.refusal(
            for: .addIndex(Self.index(columns: ["a"], includedColumns: [])),
            capabilities: PostgreSQLCapabilities(serverVersion: 100_021)
        ) == nil)
        #expect(!PostgreSQLCapabilities(serverVersion: 100_021).hasCoveringIndexes)
        #expect(PostgreSQLCapabilities(serverVersion: 110_000).hasCoveringIndexes)
    }
}
