//
//  OracleTableDDLTests.swift
//  TableProTests
//
//  The Oracle plugin's table DDL writes each column in the order Oracle's grammar takes it. Every statement below
//  was run against Oracle 23ai and created the table it describes.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleTableDDLTests {
    private func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func column(
        _ name: String,
        _ type: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        identity: IdentityKind? = nil,
        virtualExpression: String? = nil,
        ddlSpelling: String? = nil
    ) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: type,
            isNullable: nullable,
            isPrimaryKey: false,
            defaultValue: defaultValue,
            extra: nil,
            charset: nil,
            collation: nil,
            comment: nil,
            identityKind: identity,
            isGenerated: virtualExpression != nil,
            allowedValues: nil,
            generationExpression: virtualExpression,
            generationKind: virtualExpression == nil ? nil : .virtual,
            ddlSpelling: ddlSpelling,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: nil
        )
    }

    private func definition(_ column: PluginColumnInfo) -> String {
        OracleTableDDL.columnDefinition(column, quote: quote)
    }

    /// `NOT NULL DEFAULT 5` fails with ORA-03076.
    @Test("DEFAULT comes before NOT NULL")
    func defaultBeforeNotNull() {
        #expect(definition(column("A", "NUMBER(10)", nullable: false, defaultValue: "5"))
            == "\"A\" NUMBER(10) DEFAULT 5 NOT NULL")
        #expect(definition(column("S", "VARCHAR2(10 CHAR)", nullable: false, defaultValue: "ON NULL 'x'"))
            == "\"S\" VARCHAR2(10 CHAR) DEFAULT ON NULL 'x' NOT NULL")
    }

    /// A SQL export writes every row with its key, which a `GENERATED ALWAYS` identity refuses (ORA-32795).
    @Test("An identity column is written as a plain column, so a restore keeps the dump's keys")
    func identity() {
        #expect(definition(column("ID", "NUMBER", nullable: false, identity: .always)) == "\"ID\" NUMBER NOT NULL")
        #expect(definition(column("ID", "NUMBER", nullable: false, identity: .byDefault)) == "\"ID\" NUMBER NOT NULL")
    }

    @Test("A virtual column is written with its expression, not as a stored one")
    func virtualColumn() {
        #expect(definition(column("V", "NUMBER", virtualExpression: "\"A\"*2"))
            == "\"V\" NUMBER GENERATED ALWAYS AS (\"A\"*2) VIRTUAL")
        #expect(definition(column("V", "NUMBER", nullable: false, virtualExpression: "\"B\"+1"))
            == "\"V\" NUMBER GENERATED ALWAYS AS (\"B\"+1) VIRTUAL NOT NULL")
    }

    /// `"Hunt_Mixed"` folded to `HUNT_MIXED` names no type (ORA-00902), and `TIMESTAMP(6) WITH TIME ZONE` is a type
    /// only as it is spelled.
    @Test("Types are written verbatim, and a DDL spelling wins over the declared type")
    func verbatimTypes() {
        #expect(definition(column("M", "\"Hunt_Mixed\"")) == "\"M\" \"Hunt_Mixed\"")
        #expect(definition(column("TZ", "TIMESTAMP(6) WITH TIME ZONE", defaultValue: "SYSTIMESTAMP"))
            == "\"TZ\" TIMESTAMP(6) WITH TIME ZONE DEFAULT SYSTIMESTAMP")
        #expect(definition(column("X", "XMLTYPE", ddlSpelling: "\"SYS\".\"XMLTYPE\"")) == "\"X\" \"SYS\".\"XMLTYPE\"")
        #expect(definition(column("N", "NVARCHAR2(100)")) == "\"N\" NVARCHAR2(100)")
    }

    @Test("The table names every column in order and quotes names")
    func createTable() {
        let ddl = OracleTableDDL.createTable(
            qualifiedTable: "\"HR\".\"T\"",
            columns: [column("ID", "NUMBER", nullable: false, identity: .always), column("Na\"me", "VARCHAR2(5 BYTE)")],
            quote: quote
        )
        #expect(ddl == """
            CREATE TABLE "HR"."T" (
                "ID" NUMBER NOT NULL,
                "Na""me" VARCHAR2(5 BYTE)
            );
            """)
    }
}
