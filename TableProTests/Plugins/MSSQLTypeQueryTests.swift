//
//  MSSQLTypeQueryTests.swift
//  TableProTests
//
//  The catalog SQL and the CREATE TYPE synthesis for SQL Server user-defined types.
//

import Foundation
import Testing

@testable import TablePro

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
    /// table index reader carries. Rows come back one key at a time, so they group by index before
    /// they sort by ordinal; the caller folds them back into one index each.
    @Test("Table type index keys exclude INCLUDE columns and sort by index then key ordinal")
    func indexKeysExcludeIncludedColumns() {
        let sql = MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "t")
        #expect(sql.contains("ic.is_included_column = 0"))
        #expect(sql.contains("ORDER BY i.index_id, ic.key_ordinal"))
        #expect(sql.contains("i.type > 0"))
    }
}

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
                      typeDescription: "CLUSTERED", keys: [.init(column: "LineId", isDescending: false)]),
                .init(name: "ix_sku", isPrimaryKey: false, isUnique: false,
                      typeDescription: "NONCLUSTERED", keys: [.init(column: "Sku", isDescending: false)])
            ],
            databaseCollation: "SQL_Latin1_General_CP1_CI_AS"
        )
        #expect(sql.hasPrefix("CREATE TYPE [dbo].[OrderLineTable] AS TABLE ("))
        #expect(sql.contains("[LineId] int IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED"))
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
            indexes: [.init(name: "PK__x", isPrimaryKey: true, isUnique: true, typeDescription: "NONCLUSTERED",
                            keys: [.init(column: "a", isDescending: false), .init(column: "b", isDescending: false)])],
            databaseCollation: nil
        )
        #expect(sql.contains("PRIMARY KEY NONCLUSTERED ([a], [b])"))
        #expect(!sql.contains("[a] int NOT NULL PRIMARY KEY"))
        #expect(!sql.contains("PK__x"))
    }

    /// SQL Server defaults a primary key to CLUSTERED, so a NONCLUSTERED one replayed with a
    /// different layout and failed outright when the type also had a clustered secondary index.
    @Test("A NONCLUSTERED primary key keeps its clustering on the inline form too")
    func inlinePrimaryKeyKeepsClustering() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [.init(name: "Id", type: "int", isNullable: false)],
            indexes: [.init(name: "PK__x", isPrimaryKey: true, isUnique: true,
                            typeDescription: "NONCLUSTERED", keys: [.init(column: "Id", isDescending: false)])],
            databaseCollation: nil
        )
        #expect(sql.contains("[Id] int NOT NULL PRIMARY KEY NONCLUSTERED"))
    }

    /// A comma is legal inside a bracketed identifier, so the comma-joined string this replaced
    /// turned one column into two; and the string had nowhere to carry DESC at all.
    @Test("A descending key keeps its direction and a comma in a name stays one column")
    func descendingKeysAndCommasSurvive() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [.init(name: "Ranked", type: "int", isNullable: false),
                      .init(name: "a,b", type: "int", isNullable: false)],
            indexes: [.init(name: "ix", isPrimaryKey: false, isUnique: false, typeDescription: "NONCLUSTERED",
                            keys: [.init(column: "Ranked", isDescending: true),
                                   .init(column: "a,b", isDescending: false)])],
            databaseCollation: nil
        )
        #expect(sql.contains("INDEX [ix] NONCLUSTERED ([Ranked] DESC, [a,b])"))
    }

    /// Dropping a CHECK recreates the type with weaker validation than the original.
    @Test("CHECK constraints are carried into the rebuilt statement")
    func checkConstraintsSurvive() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [.init(name: "Amount", type: "decimal(10,2)", isNullable: true)],
            indexes: [],
            checkConstraints: ["([Amount]>=(0))"],
            databaseCollation: nil
        )
        #expect(sql.contains("CHECK ([Amount]>=(0))"))
    }

    /// Without the clause the replay makes a disk-backed type, and a hash index needs its bucket
    /// count or it cannot be created at all.
    @Test("A memory-optimized table type keeps its option and hash bucket count")
    func memoryOptimizedTableType() {
        let sql = MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "t",
            columns: [.init(name: "Id", type: "int", isNullable: false)],
            indexes: [.init(name: "ix_hash", isPrimaryKey: false, isUnique: false,
                            typeDescription: "NONCLUSTERED HASH",
                            keys: [.init(column: "Id", isDescending: false)], bucketCount: 1_024)],
            isMemoryOptimized: true,
            databaseCollation: nil
        )
        #expect(sql.contains("INDEX [ix_hash] HASH ([Id]) WITH (BUCKET_COUNT = 1024)"))
        #expect(sql.hasSuffix("WITH (MEMORY_OPTIMIZED = ON);"))
    }

    /// A table-type column can itself be an alias or CLR type, and a bare name binds to a different
    /// type or fails outright when the UDT lives outside the default schema.
    @Test("A user-defined column type is rendered schema-qualified by the catalog query")
    func userDefinedColumnTypesAreQualified() {
        let sql = MSSQLTypeQueries.tableTypeColumns(schema: "dbo", name: "t")
        #expect(sql.contains("bt.is_user_defined = 1"))
        #expect(sql.contains("SCHEMA_NAME(bt.schema_id)"))
    }

    @Test("Index keys and check constraints are read as structured catalog rows")
    func indexAndCheckQueriesAreStructured() {
        let indexes = MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "t")
        #expect(indexes.contains("ic.is_descending_key"))
        #expect(indexes.contains("sys.hash_indexes"))
        #expect(!indexes.contains("FOR XML PATH"))
        #expect(MSSQLTypeQueries.tableTypeCheckConstraints(schema: "dbo", name: "t")
            .contains("sys.check_constraints"))
    }

    /// A CLR type's managed class is free to differ from the SQL type's name, and substituting the
    /// SQL name produced an EXTERNAL NAME pointing at a class that does not exist.
    @Test("A CLR type names its assembly")
    func clrStatementNamesTheAssembly() {
        #expect(MSSQLTypeDefinition.clrStatement(schema: "dbo", name: "Geo", assembly: "SpatialLib", assemblyClass: "Spatial.Point")
            == "CREATE TYPE [dbo].[Geo] EXTERNAL NAME [SpatialLib].[Spatial.Point];")
    }
}
