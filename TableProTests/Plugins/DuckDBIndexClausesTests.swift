//
//  DuckDBIndexClausesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("DuckDB index clauses")
struct DuckDBIndexClausesTests {
    private func keys(_ sql: String?) -> DuckDBIndexClauses.KeyParts {
        DuckDBIndexClauses.keyParts(ofCreateIndex: sql)
    }

    @Test("A parenthesized key in duckdb_indexes().sql is an expression, the rest are columns")
    func expressionKeysAreRead() {
        #expect(keys("CREATE INDEX i_mix ON t(id, (COALESCE(a, b)));") == DuckDBIndexClauses.KeyParts(
            columns: ["id", "COALESCE(a, b)"], expressions: ["COALESCE(a, b)"]
        ))
        #expect(keys("CREATE INDEX i_fn ON t((lower(v)));").expressions == ["lower(v)"])
    }

    @Test("DuckDB's own deparse keeps its inner parentheses and doubled quotes")
    func deparsedExpressionsAreKept() {
        #expect(keys("CREATE INDEX i_concat ON t((((a || ', ') || b)));").columns == ["((a || ', ') || b)"])
        #expect(keys("CREATE INDEX i_str ON t(((a || 'it''s')));").columns == ["(a || 'it''s')"])
        #expect(
            keys("CREATE INDEX i_case ON t((CASE  WHEN ((a IS NULL)) THEN (b) ELSE a END));").columns
                == ["CASE  WHEN ((a IS NULL)) THEN (b) ELSE a END"]
        )
    }

    @Test("A quoted column name is read without its quotes, commas included")
    func quotedColumnsAreUnquoted() {
        #expect(keys(#"CREATE INDEX i_quoted ON t("we ird", "Weird, Name", "say ""hi""");"#) == DuckDBIndexClauses.KeyParts(
            columns: ["we ird", "Weird, Name", #"say "hi""#], expressions: []
        ))
        #expect(keys(#"CREATE INDEX "Mixed (Name)" ON main.t(id);"#).columns == ["id"])
    }

    @Test("An index with no statement has no key parts to read")
    func missingStatement() {
        #expect(keys(nil) == DuckDBIndexClauses.KeyParts(columns: [], expressions: []))
    }

    @Test("The writer parenthesizes an expression and quotes a column")
    func writer() {
        let index = PluginIndexDefinition(
            name: "i_mix",
            columns: ["id", "COALESCE(a, b)"],
            isUnique: true,
            expressions: ["COALESCE(a, b)"],
            includedColumns: nil,
            ddlMethodAndKeys: nil,
            ddlWhereClause: nil
        )
        let sql = DuckDBIndexClauses.createStatement(for: index, qualifiedTable: #""main"."t""#) { "\"\($0)\"" }
        #expect(sql == #"CREATE UNIQUE INDEX "i_mix" ON "main"."t" ("id", (COALESCE(a, b)))"#)
    }
}
