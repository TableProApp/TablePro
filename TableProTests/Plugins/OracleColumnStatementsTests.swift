//
//  OracleColumnStatementsTests.swift
//  TableProTests
//
//  The Oracle plugin's column MODIFY names only what changed. Every statement below was run against Oracle 23ai with
//  the outcome its test names.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleColumnStatementsTests {
    private static let table = "\"HR\".\"T\""

    private func quote(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func modify(_ old: PluginColumnDefinition, _ new: PluginColumnDefinition) -> String? {
        OracleColumnStatements.modify(qualifiedTable: Self.table, oldColumn: old, newColumn: new, quote: quote)
    }

    private func column(
        _ name: String = "A",
        type: String = "NUMBER(10,2)",
        nullable: Bool = true,
        defaultValue: String? = nil,
        comment: String? = nil
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name, dataType: type, isNullable: nullable, defaultValue: defaultValue, comment: comment
        )
    }

    /// Restating `NOT NULL` on a column that has it fails the statement with ORA-01442.
    @Test("A default changed on a NOT NULL column names the default alone")
    func defaultOnANotNullColumn() {
        let sql = modify(
            column(nullable: false, defaultValue: "1"),
            column(nullable: false, defaultValue: "2")
        )
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" DEFAULT 2)")
    }

    /// Restating the displayed type turned a `VARCHAR2(20 CHAR)` column into `VARCHAR2(80)` bytes.
    @Test("A nullability change names neither the type nor the default")
    func nullabilityAlone() {
        let sql = modify(
            column("B", type: "VARCHAR2(80)", nullable: true, defaultValue: "'q'"),
            column("B", type: "VARCHAR2(80)", nullable: false, defaultValue: "'q'")
        )
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"B\" NOT NULL)")
    }

    @Test("A column made nullable says NULL")
    func madeNullable() {
        let sql = modify(column(nullable: false), column(nullable: true))
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" NULL)")
    }

    @Test("A type change names the type alone")
    func typeAlone() {
        let sql = modify(
            column(nullable: false, defaultValue: "1"),
            column(type: "NUMBER(12,2)", nullable: false, defaultValue: "1")
        )
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" NUMBER(12,2))")
    }

    /// `"Hunt_Mixed"` folded to `"HUNT_MIXED"` names no type (ORA-00902), and a lowercase built-in type is valid as typed.
    @Test("A changed type is written as given")
    func typeWrittenVerbatim() {
        let object = modify(column("O", type: "\"Old_Type\""), column("O", type: "\"Hunt_Mixed\""))
        #expect(object == "ALTER TABLE \"HR\".\"T\" MODIFY (\"O\" \"Hunt_Mixed\")")
        let builtIn = modify(column("N", type: "NVARCHAR2(10)"), column("N", type: "nvarchar2(20)"))
        #expect(builtIn == "ALTER TABLE \"HR\".\"T\" MODIFY (\"N\" nvarchar2(20))")
    }

    @Test("A type that differs only in case is not a change")
    func typeCaseIsNotAChange() {
        #expect(modify(column(type: "NUMBER(10,2)"), column(type: "number(10,2)")) == nil)
    }

    /// Oracle cannot take a default away, so no default is `DEFAULT NULL`.
    @Test("Removing a default writes DEFAULT NULL")
    func removedDefault() {
        let sql = modify(column(defaultValue: "sysdate"), column(defaultValue: nil))
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" DEFAULT NULL)")
    }

    /// `DEFAULT ON NULL 'y'` keeps the semantics; `DEFAULT 'y'` alone drops them and makes the column nullable.
    @Test("A DEFAULT ON NULL value is written with its ON NULL")
    func defaultOnNull() {
        let sql = modify(
            column("S", type: "VARCHAR2(10)", nullable: false, defaultValue: "ON NULL 'x'"),
            column("S", type: "VARCHAR2(10)", nullable: false, defaultValue: "ON NULL 'y'")
        )
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"S\" DEFAULT ON NULL 'y')")
    }

    @Test("A change to the comment alone modifies nothing")
    func commentAlone() {
        #expect(modify(column(defaultValue: "1", comment: "old"), column(defaultValue: "1", comment: "new")) == nil)
        #expect(modify(column(defaultValue: "1"), column(defaultValue: "1")) == nil)
    }

    @Test("Every attribute that changed is named, in Oracle's order")
    func everythingChanged() {
        let sql = modify(
            column(type: "NUMBER(10,2)", nullable: true, defaultValue: nil),
            column(type: "NUMBER(12,2)", nullable: false, defaultValue: "0")
        )
        #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" NUMBER(12,2) DEFAULT 0 NOT NULL)")
    }

    @Test("A rename comes first, and the modify uses the new name")
    func renameThenModify() {
        let sql = modify(column("OLD", defaultValue: "1"), column("NEW", defaultValue: "2"))
        #expect(sql == """
            ALTER TABLE "HR"."T" RENAME COLUMN "OLD" TO "NEW";
            ALTER TABLE "HR"."T" MODIFY ("NEW" DEFAULT 2)
            """)
    }

    // MARK: - Column definition

    private func definition(
        _ column: PluginColumnDefinition,
        inlinePrimaryKey: Bool = false,
        supportsIdentity: Bool = true
    ) -> String {
        OracleColumnStatements.definition(
            column, inlinePrimaryKey: inlinePrimaryKey, supportsIdentity: supportsIdentity, quote: quote
        )
    }

    private func autoIncrement(
        _ name: String = "ID",
        nullable: Bool = false,
        primaryKey: Bool = true,
        defaultValue: String? = nil
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: name, dataType: "NUMBER", isNullable: nullable, defaultValue: defaultValue,
            isPrimaryKey: primaryKey, autoIncrement: true
        )
    }

    @Test("An auto-increment column is an identity that still takes an explicit key")
    func autoIncrementIsIdentity() {
        #expect(definition(autoIncrement(), inlinePrimaryKey: true)
            == "\"ID\" NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY PRIMARY KEY")
    }

    /// `ON NULL` already makes the column NOT NULL, and an identity takes no DEFAULT.
    @Test("An identity writes neither a default nor NOT NULL")
    func identityWritesNoDefaultOrNullability() {
        #expect(definition(autoIncrement(nullable: false, primaryKey: false, defaultValue: "0"))
            == "\"ID\" NUMBER GENERATED BY DEFAULT ON NULL AS IDENTITY")
    }

    @Test("Without identity columns the column is written as before")
    func noIdentityBefore12c() {
        #expect(definition(autoIncrement(nullable: false), inlinePrimaryKey: true, supportsIdentity: false)
            == "\"ID\" NUMBER NOT NULL PRIMARY KEY")
    }

    @Test("A plain column keeps Oracle's order: type, DEFAULT, NOT NULL, key")
    func plainColumnOrder() {
        let column = PluginColumnDefinition(
            name: "S", dataType: "VARCHAR2(10)", isNullable: false, defaultValue: "'x'", isPrimaryKey: true
        )
        #expect(definition(column, inlinePrimaryKey: true) == "\"S\" VARCHAR2(10) DEFAULT 'x' NOT NULL PRIMARY KEY")
        #expect(definition(column, inlinePrimaryKey: false) == "\"S\" VARCHAR2(10) DEFAULT 'x' NOT NULL")
    }

    // MARK: - Column comments

    @Test("Create Table comments each column that has a comment, and only those")
    func createTableColumnComments() {
        let statements = OracleColumnStatements.commentStatements(
            qualifiedTable: Self.table,
            columns: [column("A", comment: "It's A"), column("B"), column("C", comment: "")]
        )
        #expect(statements == ["COMMENT ON COLUMN \"HR\".\"T\".\"A\" IS 'It''s A'"])
    }

    /// Every value the Default menu offers for Oracle reaches the server as the text after `DEFAULT`.
    @Test("Every Oracle menu value survives the modify writer")
    func menuValuesSurvive() {
        let values = ColumnDefaultVocabulary.options(for: .oracle).compactMap(\.sql)
        #expect(!values.isEmpty)
        for value in values {
            let sql = modify(column(type: "DATE", defaultValue: nil), column(type: "DATE", defaultValue: value))
            #expect(sql == "ALTER TABLE \"HR\".\"T\" MODIFY (\"A\" DEFAULT \(value))", "\(value)")
        }
    }
}
