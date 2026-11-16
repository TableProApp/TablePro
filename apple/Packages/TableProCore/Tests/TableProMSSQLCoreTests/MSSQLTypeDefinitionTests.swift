import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLTypeDefinitionTests {
    @Test("An alias type names its base type and spells out its nullability")
    func aliasStatement() throws {
        #expect(try MSSQLTypeDefinition.aliasStatement(
            schema: "dbo", name: "Email", baseType: "nvarchar(320)", isNullable: false
        ) == "CREATE TYPE [dbo].[Email] FROM nvarchar(320) NOT NULL;")
        #expect(try MSSQLTypeDefinition.aliasStatement(
            schema: "dbo", name: "Code", baseType: "char(3)", isNullable: true
        ) == "CREATE TYPE [dbo].[Code] FROM char(3) NULL;")
    }

    @Test("A base type that would start a second statement is refused")
    func aliasRefusesEscapingBaseType() {
        #expect(throws: MSSQLDefinitionRefusal.self) {
            try MSSQLTypeDefinition.aliasStatement(
                schema: "dbo", name: "Bad", baseType: "int; DROP TABLE t", isNullable: true
            )
        }
    }

    @Test("A CLR type names its managed class, not the SQL type name")
    func clrStatementUsesAssemblyClass() {
        #expect(MSSQLTypeDefinition.clrStatement(
            schema: "dbo", name: "Point", assembly: "Geo", assemblyClass: "Geo.PointType"
        ) == "CREATE TYPE [dbo].[Point] EXTERNAL NAME [Geo].[Geo.PointType];")
        #expect(MSSQLTypeDefinition.clrStatement(
            schema: "dbo", name: "Point", assembly: "Geo", assemblyClass: ""
        ) == "CREATE TYPE [dbo].[Point] EXTERNAL NAME [Geo].[Point];")
    }

    @Test("A table type inlines a one-column key and leaves out the database's own collation")
    func tableStatementInlinesSingleKey() throws {
        let statement = try MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "IdList",
            columns: [
                MSSQLTypeDefinition.Column(name: "Id", type: "int", isNullable: false),
                MSSQLTypeDefinition.Column(
                    name: "Label", type: "nvarchar(50)", isNullable: true, collation: "SQL_Latin1_General_CP1_CI_AS"
                ),
            ],
            indexes: [
                MSSQLTypeDefinition.Index(
                    name: "PK__IdList", isPrimaryKey: true, isUnique: true, typeDescription: "CLUSTERED",
                    keys: [MSSQLTypeDefinition.IndexKey(column: "Id", isDescending: false)]
                ),
            ],
            databaseCollation: "SQL_Latin1_General_CP1_CI_AS"
        )
        #expect(statement == """
            CREATE TYPE [dbo].[IdList] AS TABLE (
                [Id] int NOT NULL PRIMARY KEY CLUSTERED,
                [Label] nvarchar(50) NULL
            );
            """)
    }

    @Test("A memory-optimized table type keeps its hash index and its WITH clause")
    func tableStatementMemoryOptimized() throws {
        let statement = try MSSQLTypeDefinition.tableStatement(
            schema: "dbo",
            name: "Pairs",
            columns: [
                MSSQLTypeDefinition.Column(name: "A", type: "int", isNullable: false),
                MSSQLTypeDefinition.Column(name: "B", type: "int", isNullable: false),
            ],
            indexes: [
                MSSQLTypeDefinition.Index(
                    name: "IX_Pairs", isPrimaryKey: false, isUnique: false, typeDescription: "NONCLUSTERED HASH",
                    keys: [
                        MSSQLTypeDefinition.IndexKey(column: "A", isDescending: false),
                        MSSQLTypeDefinition.IndexKey(column: "B", isDescending: true),
                    ],
                    bucketCount: 1_024
                ),
            ],
            checkConstraints: ["([A]>(0))"],
            isMemoryOptimized: true,
            databaseCollation: nil
        )
        #expect(statement == """
            CREATE TYPE [dbo].[Pairs] AS TABLE (
                [A] int NOT NULL,
                [B] int NOT NULL,
                INDEX [IX_Pairs] HASH ([A], [B] DESC) WITH (BUCKET_COUNT = 1024),
                CHECK ([A]>(0))
            )
            WITH (MEMORY_OPTIMIZED = ON);
            """)
    }

    @Test("Column rows map by position, and a row without a name is skipped")
    func columnsFromRows() {
        let columns = MSSQLTypeDefinition.columns(fromRows: [
            ["Id", "int", "0", "1,1", nil, nil, nil],
            ["Total", nil, "1", nil, "([A]+[B])", nil, nil],
            ["Note", "nvarchar(10)", "1", nil, nil, "(N'x')", "Latin1_General_CI_AS"],
            [nil, "int", "1", nil, nil, nil, nil],
        ])
        #expect(columns == [
            MSSQLTypeDefinition.Column(name: "Id", type: "int", isNullable: false, identitySpec: "1,1"),
            MSSQLTypeDefinition.Column(name: "Total", type: nil, isNullable: true, computedDefinition: "([A]+[B])"),
            MSSQLTypeDefinition.Column(
                name: "Note", type: "nvarchar(10)", isNullable: true, defaultDefinition: "(N'x')",
                collation: "Latin1_General_CI_AS"
            ),
        ])
    }

    @Test("Index rows fold into one index per index_id, keys in row order")
    func indexesFromRows() {
        let indexes = MSSQLTypeDefinition.indexes(fromRows: [
            ["PK_T", "1", "1", "CLUSTERED", "Id", "0", "1", "0"],
            ["IX_T", "0", "0", "NONCLUSTERED", "A", "0", "2", "0"],
            ["IX_T", "0", "0", "NONCLUSTERED", "B", "1", "2", "0"],
            ["IX_H", "0", "0", "NONCLUSTERED HASH", "C", "0", "3", "256"],
            ["IX_X", "0", "0", "NONCLUSTERED", nil, "0", "4", "0"],
        ])
        #expect(indexes == [
            MSSQLTypeDefinition.Index(
                name: "PK_T", isPrimaryKey: true, isUnique: true, typeDescription: "CLUSTERED",
                keys: [MSSQLTypeDefinition.IndexKey(column: "Id", isDescending: false)]
            ),
            MSSQLTypeDefinition.Index(
                name: "IX_T", isPrimaryKey: false, isUnique: false, typeDescription: "NONCLUSTERED",
                keys: [
                    MSSQLTypeDefinition.IndexKey(column: "A", isDescending: false),
                    MSSQLTypeDefinition.IndexKey(column: "B", isDescending: true),
                ]
            ),
            MSSQLTypeDefinition.Index(
                name: "IX_H", isPrimaryKey: false, isUnique: false, typeDescription: "NONCLUSTERED HASH",
                keys: [MSSQLTypeDefinition.IndexKey(column: "C", isDescending: false)],
                bucketCount: 256
            ),
        ])
    }

    @Test("Check rows give their definitions and skip a NULL one")
    func checkConstraintsFromRows() {
        #expect(MSSQLTypeDefinition.checkConstraints(fromRows: [["([A]>(0))"], [nil], []]) == ["([A]>(0))"])
    }
}
