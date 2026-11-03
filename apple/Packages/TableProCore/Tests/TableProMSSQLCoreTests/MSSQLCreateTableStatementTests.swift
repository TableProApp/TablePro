import Foundation
import TableProMSSQLCore
import TableProSQLGrammar
import Testing

struct MSSQLCreateTableStatementTests {
    private static func column(_ name: String, type: String = "int", default value: String? = nil) -> MSSQLColumnRow {
        MSSQLColumnRow(
            name: name,
            dataType: type,
            characterMaxLength: nil,
            numericPrecision: nil,
            numericScale: nil,
            isNullable: true,
            defaultValue: value,
            isIdentity: false,
            isPrimaryKey: false
        )
    }

    private static func statement(
        table: String = "t",
        columns: [MSSQLColumnRow],
        primaryKeyColumns: [String] = [],
        foreignKeys: [MSSQLForeignKeyRow] = []
    ) throws -> String {
        try MSSQLSchemaQueries.createTableStatement(
            schema: "dbo",
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            foreignKeys: foreignKeys
        )
    }

    @Test("A bracket in a column name stays inside the name")
    func bracketInColumnNamesStaysInsideTheName() throws {
        let ddl = try Self.statement(columns: [
            Self.column("a] INT); DROP TABLE [victims]; /*"),
            Self.column("*/ CREATE TABLE [z] ([y"),
        ])
        #expect(SQLStatementScanner.allStatements(in: ddl, grammar: SQLLexicalProfile.sqlServer).count == 1)
        #expect(ddl.contains("    [a]] INT); DROP TABLE [victims]]; /*] INT NULL,\n"))
        #expect(ddl.contains("    [*/ CREATE TABLE [z]] ([y] INT NULL\n);"))
    }

    @Test("A bracket in the table, key and foreign key names is doubled")
    func bracketInKeyNamesIsDoubled() throws {
        let ddl = try Self.statement(
            table: "t]x",
            columns: [Self.column("id]")],
            primaryKeyColumns: ["id]"],
            foreignKeys: [MSSQLForeignKeyRow(
                constraintName: "fk]", columnName: "id]", referencedTable: "r]", referencedColumn: "rc]"
            )]
        )
        #expect(ddl.hasPrefix("CREATE TABLE [dbo].[t]]x] (\n"))
        #expect(ddl.contains("    CONSTRAINT [PK_t]]x] PRIMARY KEY ([id]]])"))
        #expect(ddl.contains("    CONSTRAINT [fk]]] FOREIGN KEY ([id]]]) REFERENCES [r]]] ([rc]]])"))
        #expect(SQLStatementScanner.allStatements(in: ddl, grammar: SQLLexicalProfile.sqlServer).count == 1)
    }

    @Test("A default as the catalog stores it is written as it is")
    func catalogDefaultIsWritten() throws {
        let ddl = try Self.statement(columns: [Self.column("n", default: "((0))")])
        #expect(ddl == "CREATE TABLE [dbo].[t] (\n    [n] INT NULL DEFAULT ((0))\n);")
    }

    @Test("A default cut inside its literal fails the statement and names the column")
    func truncatedDefaultFailsTheStatement() {
        let cut = "('" + String(repeating: "A", count: 3_998)
        #expect(throws: MSSQLDefinitionRefusal.columnDefault("note")) {
            try Self.statement(columns: [
                Self.column("note", type: "nvarchar", default: cut),
                Self.column("next", type: "nvarchar", default: "(')); ALTER ROLE [db_owner] ADD MEMBER [mallory]; SELECT (1 --')"),
            ])
        }
    }

    @Test("A type that would start a statement fails the statement and names the column")
    func typeThatStartsAStatementFails() {
        #expect(throws: MSSQLDefinitionRefusal.columnType("x", "INT DROP TABLE T")) {
            try Self.statement(columns: [Self.column("x", type: "int drop table t")])
        }
    }
}
