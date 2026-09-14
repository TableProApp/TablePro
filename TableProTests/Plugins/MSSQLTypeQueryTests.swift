//
//  MSSQLTypeQueryTests.swift
//  TableProTests
//
//  The catalog SQL and the CREATE TYPE synthesis for SQL Server user-defined types.
//

import Foundation
import Testing

@testable import TablePro

@Suite("MSSQL Type Catalog Queries")
struct MSSQLTypeQueryTests {
    @Test("Only user-defined types are listed, and the three kinds are separated")
    func listsOnlyUserDefinedTypes() {
        let sql = MSSQLTypeQueries.userDefinedTypeList(schema: "dbo")
        #expect(sql.contains("t.is_user_defined = 1"))
        #expect(sql.contains("WHEN t.is_table_type = 1 THEN 'TABLE'"))
        #expect(sql.contains("WHEN t.is_assembly_type = 1 THEN 'CLR'"))
        #expect(sql.contains("ELSE 'ALIAS'"))
    }

    /// `user_type_id` survives a rename and never changes, unlike the name the listing showed.
    @Test("A type is addressed by user_type_id, not by name or kind")
    func identityIsUserTypeId() {
        #expect(MSSQLTypeQueries.userDefinedTypeList(schema: "dbo")
            .contains("CONVERT(varchar(11), t.user_type_id) AS identity_id"))
    }

    /// max_length is in bytes, so an n-type is halved, and -1 is MAX. Measured against SQL Server
    /// 2022: nvarchar(320) reports 640 and nvarchar(max) reports -1.
    @Test("The base type spelling handles the byte-length and MAX traps")
    func baseTypeSpellingHandlesLengths() {
        let sql = MSSQLTypeQueries.userDefinedTypeList(schema: "dbo")
        #expect(sql.contains("bt.name IN ('nvarchar', 'nchar')"))
        #expect(sql.contains("CONVERT(varchar(11), t.max_length / 2)"))
        #expect(sql.contains("WHEN t.max_length = -1 THEN 'max'"))
        #expect(sql.contains("bt.name IN ('decimal', 'numeric')"))
    }

    @Test("A quote in a schema or type name is escaped as a national literal")
    func literalsAreEscaped() {
        #expect(MSSQLTypeQueries.userDefinedTypeList(schema: "it's").contains("N'it''s'"))
        #expect(MSSQLTypeQueries.tableTypeColumns(schema: "販売", name: "o'brien")
            .contains("N'o''brien'"))
        #expect(MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "it's").contains("N'it''s'"))
    }

    /// The hidden table behind a table type is what sys.columns is keyed on; sys.table_types alone
    /// has no columns.
    @Test("Table type columns come through type_table_object_id in declaration order")
    func tableTypeColumnsReadTheHiddenTable() {
        let sql = MSSQLTypeQueries.tableTypeColumns(schema: "dbo", name: "t")
        #expect(sql.contains("c.object_id = tt.type_table_object_id"))
        #expect(sql.contains("ORDER BY c.column_id"))
        #expect(sql.contains("sys.identity_columns"))
        #expect(sql.contains("sys.computed_columns"))
        #expect(sql.contains("sys.default_constraints"))
    }

    /// An INCLUDE column is not part of the key, and listing it as one is the same defect the
    /// table index reader carries.
    @Test("Table type index keys exclude INCLUDE columns and sort by key ordinal")
    func indexKeysExcludeIncludedColumns() {
        let sql = MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "t")
        #expect(sql.contains("ic.is_included_column = 0"))
        #expect(sql.contains("ORDER BY ic.key_ordinal"))
        #expect(sql.contains("i.type > 0"))
    }
}

@Suite("MSSQL Type Definition Synthesis")
struct MSSQLTypeDefinitionTests {
    /// Executed verbatim against SQL Server 2022 and accepted.
    @Test("An alias type rebuilds its CREATE TYPE ... FROM statement")
    func aliasStatement() {
        #expect(MSSQLTypeDefinition.aliasStatement(
            schema: "dbo", name: "EmailAddress", baseType: "nvarchar(320)", isNullable: false
        ) == "CREATE TYPE [dbo].[EmailAddress] FROM nvarchar(320) NOT NULL;")
        #expect(MSSQLTypeDefinition.aliasStatement(
            schema: "sales", name: "BigText", baseType: "nvarchar(max)", isNullable: true
        ) == "CREATE TYPE [sales].[BigText] FROM nvarchar(max) NULL;")
    }

    @Test("A bracket in a name is doubled, not left to close the identifier early")
    func bracketsAreEscaped() {
        #expect(MSSQLTypeDefinition.bracketed("a]b") == "[a]]b]")
        #expect(MSSQLTypeDefinition.aliasStatement(
            schema: "dbo", name: "a]b", baseType: "int", isNullable: true
        ).contains("[a]]b]"))
    }

    /// The whole shape, measured: this statement was executed against SQL Server 2022 and created
    /// a type matching the fixture it was rebuilt from.
    @Test("A table type rebuilds identity, default, collation, computed column and inline index")
    func tableStatement() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "OrderLineTable",
            columns: [
                .init(name: "LineId", type: "int", isNullable: false, identitySpec: "1,1"),
                .init(name: "Sku", type: "varchar(32)", isNullable: false, collation: "SQL_Latin1_General_CP1_CI_AS"),
                .init(name: "Qty", type: "int", isNullable: false, defaultDefinition: "((1))"),
                .init(name: "Price", type: "decimal(18,4)", isNullable: true),
                .init(name: "Note", type: "nvarchar(200)", isNullable: true, collation: "Latin1_General_BIN2"),
                .init(name: "Total", type: nil, isNullable: true, computedDefinition: "([Qty]*[Price])")
            ],
            indexes: [
                .init(name: "PK__TT_Order__2EAE", isPrimaryKey: true, isUnique: true,
                      typeDescription: "CLUSTERED", keyColumns: "LineId"),
                .init(name: "ix_sku", isPrimaryKey: false, isUnique: false,
                      typeDescription: "NONCLUSTERED", keyColumns: "Sku")
            ],
            databaseCollation: "SQL_Latin1_General_CP1_CI_AS"
        )
        #expect(sql.hasPrefix("CREATE TYPE [dbo].[OrderLineTable] AS TABLE ("))
        #expect(sql.contains("[LineId] int IDENTITY(1,1) NOT NULL PRIMARY KEY"))
        #expect(sql.contains("[Qty] int NOT NULL DEFAULT ((1))"))
        #expect(sql.contains("[Total] AS ([Qty]*[Price])"))
        #expect(sql.contains("INDEX [ix_sku] NONCLUSTERED ([Sku])"))
        #expect(sql.hasSuffix(");"))
    }

    /// A column keeps its collation in sys.columns whether or not it differs, so emitting it
    /// unconditionally puts a COLLATE clause on every column the user never wrote.
    @Test("Only a collation that differs from the database's is spelled out")
    func collationIsOmittedWhenItMatchesTheDatabase() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [
                .init(name: "Sku", type: "varchar(32)", isNullable: false, collation: "SQL_Latin1_General_CP1_CI_AS"),
                .init(name: "Note", type: "nvarchar(200)", isNullable: true, collation: "Latin1_General_BIN2")
            ],
            indexes: [],
            databaseCollation: "SQL_Latin1_General_CP1_CI_AS"
        )
        #expect(!sql.contains("[Sku] varchar(32) COLLATE"))
        #expect(sql.contains("[Note] nvarchar(200) COLLATE Latin1_General_BIN2 NULL"))
    }

    /// The constraint name is server-generated, so carrying it forward is noise; a multi-column key
    /// still needs its own clause because it cannot sit on one column.
    @Test("A composite primary key becomes its own clause rather than an inline one")
    func compositePrimaryKeyIsATableClause() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [
                .init(name: "a", type: "int", isNullable: false),
                .init(name: "b", type: "int", isNullable: false)
            ],
            indexes: [.init(name: "PK__x", isPrimaryKey: true, isUnique: true, keyColumns: "a, b")],
            databaseCollation: nil
        )
        #expect(sql.contains("PRIMARY KEY ([a], [b])"))
        #expect(!sql.contains("[a] int NOT NULL PRIMARY KEY"))
        #expect(!sql.contains("PK__x"))
    }

    /// A CLR type's body is in a .NET assembly, so there is nothing to rebuild and the statement
    /// says where it came from instead of inventing one.
    @Test("A CLR type names its assembly")
    func clrStatementNamesTheAssembly() {
        #expect(MSSQLTypeDefinition.clrStatement(schema: "dbo", name: "Geo", assembly: "SpatialLib")
            == "CREATE TYPE [dbo].[Geo] EXTERNAL NAME [SpatialLib].[Geo];")
    }
}
