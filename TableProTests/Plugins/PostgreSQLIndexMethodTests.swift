//
//  PostgreSQLIndexMethodTests.swift
//  TableProTests
//
//  The access method a PostgreSQL `CREATE INDEX` names when it is written from an index's fields.
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLIndexMethodTests {
    private static let table = #""dst"."items""#

    private static func index(type: String?, ddlMethodAndKeys: String? = nil) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: "ix",
            columns: ["a"],
            indexType: type,
            expressions: nil,
            includedColumns: nil,
            ddlMethodAndKeys: ddlMethodAndKeys,
            ddlWhereClause: nil
        )
    }

    /// A list of five methods wrote every other one as a b-tree. Measured on PostgreSQL 17.11: an
    /// `spgist` index over a point column written as `USING btree ("p")` is refused with `data type
    /// point has no default operator class for access method "btree"`, and `USING spgist ("p")` and
    /// `USING bloom ("a", "b")` are created as written.
    @Test("Any access method the index names is written, in the lowercase pg_am stores")
    func everyAccessMethodIsWritten() {
        for (type, method) in [("SPGIST", "spgist"), ("BLOOM", "bloom"), ("hnsw", "hnsw"), ("IVFFLAT", "ivfflat")] {
            #expect(
                PostgreSQLIndexClauses.createStatement(for: Self.index(type: type), qualifiedTable: Self.table)
                    == #"CREATE INDEX "ix" ON "dst"."items" USING \#(method) ("a")"#
            )
        }
    }

    /// Measured on PostgreSQL 17.11: `USING "sorting key"` and `USING "gsi (all)"` are refused with
    /// `access method "…" does not exist`.
    @Test("A name that is not a plain identifier is quoted, so it can only fail as a missing method")
    func unusualNamesAreQuoted() {
        #expect(PostgreSQLIndexClauses.method(for: Self.index(type: "SORTING KEY")) == #""sorting key""#)
        #expect(PostgreSQLIndexClauses.method(for: Self.index(type: "GSI (ALL)")) == #""gsi (all)""#)
        #expect(PostgreSQLIndexClauses.method(for: Self.index(type: #"x" (a); DROP TABLE t; --"#))
            == #""x"" (a); drop table t; --""#)
        #expect(PostgreSQLIndexClauses.method(for: Self.index(type: "1gin")) == #""1gin""#)
    }

    @Test("No type writes no USING clause and leaves the server's default")
    func missingTypeWritesNoMethod() {
        for type in [nil, "", "  "] {
            #expect(PostgreSQLIndexClauses.methodAndKeys(for: Self.index(type: type)) == #"("a")"#)
        }
    }

    @Test("The server's own spelling still wins over the type")
    func spellingWinsOverType() {
        let index = Self.index(type: "BTREE", ddlMethodAndKeys: "USING spgist (a)")
        #expect(PostgreSQLIndexClauses.methodAndKeys(for: index) == "USING spgist (a)")
    }

    @Test("SP-GiST is refused before PostgreSQL 9.2 and accepted from it")
    func spGistNeedsPostgreSQL92() {
        let index = Self.index(type: "spgist")
        let refusal = PostgreSQLVersionedStatements.refusal(
            for: .addIndex(index), capabilities: PostgreSQLCapabilities(serverVersion: 90_124)
        )
        #expect(refusal == "SP-GiST indexes need PostgreSQL 9.2 or later.")
        #expect(PostgreSQLVersionedStatements.refusal(
            for: .addIndex(index), capabilities: PostgreSQLCapabilities(serverVersion: 90_200)
        ) == nil)
    }

    @Test("A type outside the known list is not refused, because the server decides whether it has it")
    func extensionMethodsAreNotRefused() {
        for type in ["BLOOM", "HNSW", "RUM"] {
            #expect(PostgreSQLVersionedStatements.refusal(
                for: .addIndex(Self.index(type: type)), capabilities: PostgreSQLCapabilities(serverVersion: 170_011)
            ) == nil)
        }
    }
}
