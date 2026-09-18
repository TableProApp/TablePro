//
//  PostgreSQLColumnCollationClauseTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLColumnClauses collation")
struct PostgreSQLColumnCollationClauseTests {
    private func column(
        dataType: String = "CHARACTER VARYING",
        ddlSpelling: String? = "character varying(10)",
        collation: String? = "C",
        ddlCollation: String? = #"pg_catalog."C""#,
        autoIncrement: Bool = false
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: "code",
            dataType: dataType,
            autoIncrement: autoIncrement,
            collation: collation,
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: ddlSpelling,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: ddlCollation
        )
    }

    @Test("A column still of the type it was read as writes the collation it was read with")
    func catalogTypeWritesCollation() {
        #expect(PostgreSQLColumnClauses.collation(for: column()) == #"pg_catalog."C""#)
        #expect(
            PostgreSQLColumnClauses.collation(for: column(dataType: "TEXT", ddlSpelling: "app.ctext", collation: nil,
                                                          ddlCollation: #"pg_catalog."default""#))
                == #"pg_catalog."default""#
        )
    }

    @Test("A retype to a built-in string type keeps the collation, in every spelling the grammar has")
    func stringRetypeKeepsCollation() {
        let spellings = [
            "VARCHAR(20)", "character varying(20)[]", "character varying (20)", "BPCHAR", "text", "TEXT[]",
            "char(2)", "CHARACTER(5)", "char varying(4)", "national character varying(5)", "NCHAR(3)",
            "varchar(3)[2]"
        ]
        for spelling in spellings {
            let retyped = column(dataType: spelling, ddlSpelling: nil)
            #expect(PostgreSQLColumnClauses.collation(for: retyped) == #"pg_catalog."C""#, "\(spelling)")
        }
    }

    @Test("A retype to a type that may take no collation, or an auto-increment column, writes none")
    func otherRetypesWriteNoCollation() {
        for spelling in ["INTEGER", "JSONB", "NAME", "app.ctext", "citext", "\"char\"", "ENUM", "uuid"] {
            #expect(PostgreSQLColumnClauses.collation(for: column(dataType: spelling, ddlSpelling: nil)) == nil, "\(spelling)")
        }
        #expect(PostgreSQLColumnClauses.collation(for: column(autoIncrement: true)) == nil)
    }

    @Test("A display collation alone is never written, because it names no schema")
    func displayCollationAloneIsNotWritten() {
        #expect(PostgreSQLColumnClauses.collation(for: column(collation: "C", ddlCollation: nil)) == nil)
        #expect(PostgreSQLColumnClauses.collation(for: column(dataType: "TEXT", ddlSpelling: nil, ddlCollation: nil)) == nil)
    }

    @Test("Nothing to alter when neither the type nor the collation moved")
    func unchangedColumnAltersNothing() {
        #expect(PostgreSQLColumnClauses.alterType(old: column(), new: column()) == nil)
        #expect(PostgreSQLColumnClauses.alterType(
            old: column(dataType: "character varying"), new: column(dataType: "CHARACTER VARYING")
        ) == nil)
    }

    @Test("A retype keeps a collation the new type takes and drops one it may not")
    func retypeCarriesCollationWhereItCan() {
        #expect(
            PostgreSQLColumnClauses.alterType(old: column(), new: column(dataType: "VARCHAR(20)", ddlSpelling: nil))
                == #"VARCHAR(20) COLLATE pg_catalog."C""#
        )
        #expect(
            PostgreSQLColumnClauses.alterType(old: column(), new: column(dataType: "INTEGER", ddlSpelling: nil))
                == "INTEGER"
        )
    }

    @Test("A collation that changed on its own is a retype to the same type, with or without COLLATE")
    func collationOnlyChangeRetypesToTheSameType() {
        #expect(
            PostgreSQLColumnClauses.alterType(
                old: column(collation: nil, ddlCollation: nil),
                new: column(collation: "Case Insens", ddlCollation: #"app."Case Insens""#)
            ) == #"character varying(10) COLLATE app."Case Insens""#
        )
        #expect(
            PostgreSQLColumnClauses.alterType(old: column(), new: column(collation: nil, ddlCollation: nil))
                == "character varying(10)"
        )
    }
}
