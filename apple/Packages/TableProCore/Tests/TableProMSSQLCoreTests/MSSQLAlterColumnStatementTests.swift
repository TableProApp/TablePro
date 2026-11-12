import Foundation
import TableProMSSQLCore
import TableProSQLGrammar
import Testing

// SQL Server's ALTER TABLE docs: a column altered without COLLATE gets the database's default collation.
struct MSSQLAlterColumnStatementTests {
    @Test("Widening a character column keeps the collation it was read with")
    func wideningKeepsTheCollation() throws {
        let collation = MSSQLSchemaQueries.alterColumnCollation(
            type: "varchar(40)", collation: "Latin1_General_CS_AS", previous: "Latin1_General_CS_AS"
        )
        let sql = try MSSQLSchemaQueries.alterColumnStatement(
            qualifiedTable: "[dbo].[items]", column: "code", type: "varchar(40)", collation: collation, isNullable: true
        )
        #expect(sql == "ALTER TABLE [dbo].[items] ALTER COLUMN [code] varchar(40) COLLATE Latin1_General_CS_AS NULL")
    }

    @Test("The new definition's collation wins, and the old one stays when the new one is not known")
    func collationPrecedence() {
        #expect(MSSQLSchemaQueries.alterColumnCollation(type: "nvarchar(10)", collation: "Latin1_General_BIN2", previous: "Latin1_General_CS_AS")
            == "Latin1_General_BIN2")
        #expect(MSSQLSchemaQueries.alterColumnCollation(type: "nvarchar(10)", collation: nil, previous: "Latin1_General_CS_AS")
            == "Latin1_General_CS_AS")
        #expect(MSSQLSchemaQueries.alterColumnCollation(type: "nvarchar(10)", collation: "", previous: "Latin1_General_CS_AS")
            == "Latin1_General_CS_AS")
        #expect(MSSQLSchemaQueries.alterColumnCollation(type: "nvarchar(10)", collation: nil, previous: nil) == nil)
    }

    // ALTER COLUMN refuses COLLATE on any other type, text and ntext included.
    @Test("A type other than char, varchar, nchar or nvarchar takes no collation", arguments: [
        "int", "text", "ntext", "xml", "dbo.Code", "varbinary(20)",
    ])
    func nonCharacterTypeTakesNoCollation(type: String) {
        #expect(MSSQLSchemaQueries.alterColumnCollation(type: type, collation: "Latin1_General_CS_AS", previous: "Latin1_General_CS_AS") == nil)
    }

    @Test("A column without a collation is altered as before")
    func noCollation() throws {
        let sql = try MSSQLSchemaQueries.alterColumnStatement(
            qualifiedTable: "[dbo].[items]", column: "qty", type: "bigint", collation: nil, isNullable: false
        )
        #expect(sql == "ALTER TABLE [dbo].[items] ALTER COLUMN [qty] bigint NOT NULL")
    }

    @Test("A collation that is not a collation name fails the statement and names the column")
    func collationThatIsNotANameIsRefused() {
        let text = "Latin1_General_CS_AS NULL; DROP TABLE t; --"
        #expect(throws: MSSQLDefinitionRefusal.collation("code", text)) {
            try MSSQLSchemaQueries.alterColumnStatement(
                qualifiedTable: "[dbo].[items]", column: "code", type: "varchar(40)", collation: text, isNullable: true
            )
        }
    }

    @Test("A type that would start a statement fails the statement and names the column")
    func typeThatStartsAStatementIsRefused() {
        #expect(throws: MSSQLDefinitionRefusal.columnType("code", "varchar(40) DROP TABLE t")) {
            try MSSQLSchemaQueries.alterColumnStatement(
                qualifiedTable: "[dbo].[items]", column: "code", type: "varchar(40) DROP TABLE t", collation: nil, isNullable: true
            )
        }
    }

    @Test("A bracket in the column name stays inside the name")
    func bracketInColumnName() throws {
        let sql = try MSSQLSchemaQueries.alterColumnStatement(
            qualifiedTable: "[dbo].[items]", column: "a] int; DROP TABLE t; --", type: "int", collation: nil, isNullable: true
        )
        #expect(sql == "ALTER TABLE [dbo].[items] ALTER COLUMN [a]] int; DROP TABLE t; --] int NULL")
        #expect(SQLStatementScanner.allStatements(in: sql, grammar: SQLLexicalProfile.sqlServer).count == 1)
    }
}
