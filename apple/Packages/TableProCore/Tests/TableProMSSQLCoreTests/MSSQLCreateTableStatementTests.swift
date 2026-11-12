import Foundation
import TableProMSSQLCore
import TableProSQLGrammar
import Testing

struct MSSQLCreateTableStatementTests {
    private static let serverDefault = "SQL_Latin1_General_CP1_CI_AS"

    private static func column(
        _ name: String,
        type: String = "int",
        length: Int? = nil,
        nullable: Bool = true,
        default value: String? = nil,
        collation: String? = nil
    ) -> MSSQLColumnRow {
        MSSQLColumnRow(
            name: name,
            dataType: type,
            characterMaxLength: length,
            numericPrecision: nil,
            numericScale: nil,
            isNullable: nullable,
            defaultValue: value,
            isIdentity: false,
            isPrimaryKey: false,
            collation: collation
        )
    }

    private static func computed(
        _ name: String,
        definition: String?,
        persisted: Bool = false,
        nullable: Bool = true
    ) -> MSSQLColumnRow {
        MSSQLColumnRow(
            name: name,
            dataType: "numeric",
            characterMaxLength: nil,
            numericPrecision: 21,
            numericScale: 2,
            isNullable: nullable,
            defaultValue: nil,
            isIdentity: false,
            isPrimaryKey: false,
            isComputed: true,
            computedDefinition: definition,
            isPersisted: persisted
        )
    }

    private static func identity(_ name: String, seed: String?, increment: String?) -> MSSQLColumnRow {
        MSSQLColumnRow(
            name: name,
            dataType: "int",
            characterMaxLength: nil,
            numericPrecision: 10,
            numericScale: 0,
            isNullable: false,
            defaultValue: nil,
            isIdentity: true,
            isPrimaryKey: true,
            identitySeed: seed,
            identityIncrement: increment
        )
    }

    private static func statement(
        table: String = "t",
        columns: [MSSQLColumnRow],
        keyConstraints: [MSSQLKeyConstraintRow] = [],
        checkConstraints: [MSSQLCheckConstraintRow] = [],
        foreignKeys: [MSSQLForeignKeyRow] = [],
        databaseCollation: String? = serverDefault
    ) throws -> String {
        try MSSQLSchemaQueries.createTableStatement(
            schema: "dbo",
            table: table,
            columns: columns,
            keyConstraints: keyConstraints,
            checkConstraints: checkConstraints,
            foreignKeys: foreignKeys,
            databaseCollation: databaseCollation
        )
    }

    private static func statementCount(_ ddl: String) -> Int {
        SQLStatementScanner.allStatements(in: ddl, grammar: SQLLexicalProfile.sqlServer).count
    }

    @Test("A bracket in a column name stays inside the name")
    func bracketInColumnNamesStaysInsideTheName() throws {
        let ddl = try Self.statement(columns: [
            Self.column("a] INT); DROP TABLE [victims]; /*"),
            Self.column("*/ CREATE TABLE [z] ([y"),
        ])
        #expect(Self.statementCount(ddl) == 1)
        #expect(ddl.contains("    [a]] INT); DROP TABLE [victims]]; /*] INT NULL,\n"))
        #expect(ddl.contains("    [*/ CREATE TABLE [z]] ([y] INT NULL\n);"))
    }

    @Test("A bracket in the table, key, constraint and referenced names is doubled")
    func bracketInKeyNamesIsDoubled() throws {
        let ddl = try Self.statement(
            table: "t]x",
            columns: [Self.column("id]")],
            keyConstraints: [
                MSSQLKeyConstraintRow(name: "pk]", isPrimaryKey: true, indexKind: "CLUSTERED", columnName: "id]"),
                MSSQLKeyConstraintRow(name: "uq]", isPrimaryKey: false, indexKind: "NONCLUSTERED", columnName: "id]"),
            ],
            checkConstraints: [MSSQLCheckConstraintRow(name: "ck]", definition: "([id]]]>(0))")],
            foreignKeys: [MSSQLForeignKeyRow(
                constraintName: "fk]", columnName: "id]", referencedTable: "r]", referencedColumn: "rc]", referencedSchema: "s]"
            )]
        )
        #expect(ddl.hasPrefix("CREATE TABLE [dbo].[t]]x] (\n"))
        #expect(ddl.contains("    CONSTRAINT [pk]]] PRIMARY KEY CLUSTERED ([id]]])"))
        #expect(ddl.contains("    CONSTRAINT [uq]]] UNIQUE NONCLUSTERED ([id]]])"))
        #expect(ddl.contains("    CONSTRAINT [fk]]] FOREIGN KEY ([id]]]) REFERENCES [s]]].[r]]] ([rc]]])"))
        #expect(ddl.contains("    CONSTRAINT [ck]]] CHECK ([id]]]>(0))"))
        #expect(Self.statementCount(ddl) == 1)
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

    @Test("Every clause lands in one statement: columns, then the primary key, UNIQUE, FOREIGN KEY and CHECK")
    func clauseOrder() throws {
        let ddl = try Self.statement(
            table: "order_lines",
            columns: [Self.column("order_id", nullable: false), Self.column("line_no", nullable: false)],
            keyConstraints: [
                MSSQLKeyConstraintRow(name: "UQ_line", isPrimaryKey: false, indexKind: "NONCLUSTERED", columnName: "line_no"),
                MSSQLKeyConstraintRow(name: "PK_order_lines", isPrimaryKey: true, indexKind: "CLUSTERED", columnName: "order_id"),
                MSSQLKeyConstraintRow(name: "PK_order_lines", isPrimaryKey: true, indexKind: "CLUSTERED", columnName: "line_no"),
            ],
            checkConstraints: [MSSQLCheckConstraintRow(name: "CK_line", definition: "([line_no]>(0))")],
            foreignKeys: [MSSQLForeignKeyRow(
                constraintName: "FK_order", columnName: "order_id", referencedTable: "orders", referencedColumn: "id", referencedSchema: "dbo"
            )]
        )
        #expect(ddl == """
            CREATE TABLE [dbo].[order_lines] (
                [order_id] INT NOT NULL,
                [line_no] INT NOT NULL,
                CONSTRAINT [PK_order_lines] PRIMARY KEY CLUSTERED ([order_id], [line_no]),
                CONSTRAINT [UQ_line] UNIQUE NONCLUSTERED ([line_no]),
                CONSTRAINT [FK_order] FOREIGN KEY ([order_id]) REFERENCES [dbo].[orders] ([id]),
                CONSTRAINT [CK_line] CHECK ([line_no]>(0))
            );
            """)
        #expect(Self.statementCount(ddl) == 1)
    }

    // Each catalog row is one key column, and writing one constraint per row declared FK_x twice: error 2714 on restore.
    @Test("A composite foreign key is one constraint with its columns in key order")
    func compositeForeignKey() throws {
        let ddl = try Self.statement(
            table: "shipments",
            columns: [Self.column("order_id"), Self.column("line_no")],
            foreignKeys: [
                MSSQLForeignKeyRow(
                    constraintName: "FK_x", columnName: "order_id", referencedTable: "order_lines",
                    referencedColumn: "order_id", referencedSchema: "dbo"
                ),
                MSSQLForeignKeyRow(
                    constraintName: "FK_x", columnName: "line_no", referencedTable: "order_lines",
                    referencedColumn: "line_no", referencedSchema: "dbo"
                ),
            ]
        )
        #expect(ddl == """
            CREATE TABLE [dbo].[shipments] (
                [order_id] INT NULL,
                [line_no] INT NULL,
                CONSTRAINT [FK_x] FOREIGN KEY ([order_id], [line_no]) REFERENCES [dbo].[order_lines] ([order_id], [line_no])
            );
            """)
    }

    @Test("A key into another schema names that schema and keeps its ON DELETE action")
    func crossSchemaForeignKeyWithCascade() throws {
        let ddl = try Self.statement(
            columns: [Self.column("order_id")],
            foreignKeys: [MSSQLForeignKeyRow(
                constraintName: "FK_orders", columnName: "order_id", referencedTable: "orders", referencedColumn: "id",
                referencedSchema: "sales", onDelete: "CASCADE", onUpdate: "NO ACTION"
            )]
        )
        #expect(ddl.contains("    CONSTRAINT [FK_orders] FOREIGN KEY ([order_id]) REFERENCES [sales].[orders] ([id]) ON DELETE CASCADE\n"))
        #expect(!ddl.contains("ON UPDATE"))
    }

    @Test("Both actions read from the catalog are written after the reference")
    func catalogActionsAreWritten() throws {
        let row = try #require(MSSQLSchemaQueries.parseForeignKeyRow(
            ["FK_a", "a_id", "a", "id", "sales", "SET_NULL", "CASCADE", "t"]
        ))
        let ddl = try Self.statement(columns: [Self.column("a_id")], foreignKeys: [row])
        #expect(ddl.contains("REFERENCES [sales].[a] ([id]) ON DELETE SET NULL ON UPDATE CASCADE\n"))
    }

    @Test("A key with no referenced schema is qualified with the table's own")
    func foreignKeyWithoutSchemaUsesTheTablesSchema() throws {
        let ddl = try Self.statement(
            columns: [Self.column("a_id")],
            foreignKeys: [MSSQLForeignKeyRow(constraintName: "FK_a", columnName: "a_id", referencedTable: "a", referencedColumn: "id")]
        )
        #expect(ddl.contains("REFERENCES [dbo].[a] ([id])"))
    }

    @Test("An action SQL Server does not have fails the statement and names the key")
    func unknownActionIsRefused() {
        #expect(throws: MSSQLDefinitionRefusal.foreignKeyAction("FK_a", "CASCADE; DROP TABLE t")) {
            try Self.statement(
                columns: [Self.column("a_id")],
                foreignKeys: [MSSQLForeignKeyRow(
                    constraintName: "FK_a", columnName: "a_id", referencedTable: "a", referencedColumn: "id",
                    onDelete: "CASCADE; DROP TABLE t"
                )]
            )
        }
    }

    @Test("The primary key keeps its catalog name, its kind and each column's direction")
    func primaryKeyKeepsItsName() throws {
        let ddl = try Self.statement(
            columns: [Self.column("a", nullable: false), Self.column("b", nullable: false)],
            keyConstraints: [
                MSSQLKeyConstraintRow(name: "PK__t__3213E83F", isPrimaryKey: true, indexKind: "NONCLUSTERED", columnName: "a"),
                MSSQLKeyConstraintRow(
                    name: "PK__t__3213E83F", isPrimaryKey: true, indexKind: "NONCLUSTERED", columnName: "b", isDescending: true
                ),
            ]
        )
        #expect(ddl.contains("    CONSTRAINT [PK__t__3213E83F] PRIMARY KEY NONCLUSTERED ([a], [b] DESC)\n"))
        #expect(!ddl.contains("PK_t]"))
    }

    @Test("A UNIQUE constraint is declared with its kind and its columns in key order")
    func uniqueConstraint() throws {
        let ddl = try Self.statement(
            columns: [Self.column("code", type: "varchar", length: 20), Self.column("region")],
            keyConstraints: [
                MSSQLKeyConstraintRow(name: "UQ_code", isPrimaryKey: false, indexKind: "CLUSTERED", columnName: "code"),
                MSSQLKeyConstraintRow(
                    name: "UQ_code", isPrimaryKey: false, indexKind: "CLUSTERED", columnName: "region", isDescending: true
                ),
            ]
        )
        #expect(ddl.contains("    CONSTRAINT [UQ_code] UNIQUE CLUSTERED ([code], [region] DESC)\n"))
    }

    @Test("A kind other than the two rowstore kinds is left to the server's default")
    func unknownKeyKindIsOmitted() throws {
        let ddl = try Self.statement(
            columns: [Self.column("code")],
            keyConstraints: [MSSQLKeyConstraintRow(
                name: "UQ_code", isPrimaryKey: false, indexKind: "CLUSTERED; DROP TABLE t; --", columnName: "code"
            )]
        )
        #expect(ddl.contains("    CONSTRAINT [UQ_code] UNIQUE ([code])\n"))
        #expect(Self.statementCount(ddl) == 1)
    }

    @Test("A CHECK constraint is written with its name and the expression the catalog stores")
    func checkConstraint() throws {
        let ddl = try Self.statement(
            columns: [Self.column("qty")],
            checkConstraints: [MSSQLCheckConstraintRow(name: "CK_qty", definition: "([qty]>(0))")]
        )
        #expect(ddl == "CREATE TABLE [dbo].[t] (\n    [qty] INT NULL,\n    CONSTRAINT [CK_qty] CHECK ([qty]>(0))\n);")
    }

    @Test("A CHECK whose text reaches past one expression fails the statement")
    func escapingCheckIsRefused() {
        #expect(throws: MSSQLDefinitionRefusal.checkConstraint("t")) {
            try Self.statement(
                columns: [Self.column("qty")],
                checkConstraints: [MSSQLCheckConstraintRow(name: "CK_qty", definition: "([qty]>(0))) DROP TABLE t; --")]
            )
        }
    }

    @Test("A disabled or untrusted CHECK is switched off before the rows, and an untrusted one back on after them")
    func uncheckedCheckConstraints() throws {
        let checks = [
            MSSQLCheckConstraintRow(name: "CK_off", definition: "([qty]>(0))", isDisabled: true, isNotTrusted: true),
            MSSQLCheckConstraintRow(name: "CK_loose", definition: "([qty]<(9))", isNotTrusted: true),
            MSSQLCheckConstraintRow(name: "CK_on", definition: "([qty]<>(5))"),
        ]
        let ddl = try Self.statement(columns: [Self.column("qty")], checkConstraints: checks)
        #expect(ddl.hasSuffix("""
            );
            ALTER TABLE [dbo].[t] NOCHECK CONSTRAINT [CK_off];
            ALTER TABLE [dbo].[t] NOCHECK CONSTRAINT [CK_loose];
            """))
        #expect(Self.statementCount(ddl) == 3)
        #expect(MSSQLSchemaQueries.checkConstraintReenableStatements(schema: "dbo", table: "t", checkConstraints: checks)
            == ["ALTER TABLE [dbo].[t] WITH NOCHECK CHECK CONSTRAINT [CK_loose];"])
    }

    @Test("A CHECK with no readable definition is left out")
    func unreadableCheckIsLeftOut() throws {
        let ddl = try Self.statement(
            columns: [Self.column("qty")],
            checkConstraints: [MSSQLCheckConstraintRow(name: "CK_qty", definition: nil)]
        )
        #expect(!ddl.contains("CHECK"))
    }

    @Test("A computed column is written as its expression, not as a plain column of its result type")
    func computedColumn() throws {
        let ddl = try Self.statement(columns: [
            Self.column("qty"),
            Self.computed("total", definition: "([qty]*[price])", nullable: false),
        ])
        #expect(ddl.contains("    [total] AS ([qty]*[price])\n"))
        #expect(!ddl.contains("NUMERIC"))
    }

    @Test("A persisted computed column keeps PERSISTED, and NOT NULL only with it")
    func persistedComputedColumn() throws {
        let notNull = try Self.statement(columns: [Self.computed("total", definition: "([qty]*[price])", persisted: true, nullable: false)])
        #expect(notNull.contains("    [total] AS ([qty]*[price]) PERSISTED NOT NULL\n"))

        let nullable = try Self.statement(columns: [Self.computed("total", definition: "([qty]*[price])", persisted: true)])
        #expect(nullable.contains("    [total] AS ([qty]*[price]) PERSISTED\n"))
    }

    @Test("A computed expression that is not one expression, or cannot be read, fails the statement", arguments: [
        "([qty]*[price])) DROP TABLE t; --", nil,
    ])
    func unwritableComputedColumnIsRefused(definition: String?) {
        #expect(throws: MSSQLDefinitionRefusal.computedColumn("total")) {
            try Self.statement(columns: [Self.computed("total", definition: definition)])
        }
    }

    @Test("An identity keeps its seed and increment")
    func identitySeedAndIncrement() throws {
        let ddl = try Self.statement(columns: [Self.identity("id", seed: "1000", increment: "5")])
        #expect(ddl == "CREATE TABLE [dbo].[t] (\n    [id] INT IDENTITY(1000,5) NOT NULL\n);")

        let descending = try Self.statement(columns: [Self.identity("id", seed: "-1", increment: "-1")])
        #expect(descending.contains("[id] INT IDENTITY(-1,-1) NOT NULL"))
    }

    @Test("An identity without a whole-number seed and increment fails the statement")
    func unreadableIdentityIsRefused() {
        #expect(throws: MSSQLDefinitionRefusal.identity("id", ",")) {
            try Self.statement(columns: [Self.identity("id", seed: nil, increment: nil)])
        }
        #expect(throws: MSSQLDefinitionRefusal.identity("id", "1) NOT NULL, [x] INT --,1")) {
            try Self.statement(columns: [Self.identity("id", seed: "1) NOT NULL, [x] INT --", increment: "1")])
        }
    }

    @Test("A collation other than the database's is written after the type")
    func differingCollationIsWritten() throws {
        let ddl = try Self.statement(columns: [
            Self.column("code", type: "varchar", length: 20, collation: "Latin1_General_CS_AS"),
        ])
        #expect(ddl == "CREATE TABLE [dbo].[t] (\n    [code] VARCHAR(20) COLLATE Latin1_General_CS_AS NULL\n);")
    }

    @Test("The database's own collation is not written")
    func databaseCollationIsNotWritten() throws {
        let ddl = try Self.statement(columns: [
            Self.column("code", type: "varchar", length: 20, collation: Self.serverDefault),
        ])
        #expect(ddl == "CREATE TABLE [dbo].[t] (\n    [code] VARCHAR(20) NULL\n);")
    }

    @Test("Without the database's collation every column states its own")
    func unknownDatabaseCollationWritesEveryCollation() throws {
        let ddl = try Self.statement(
            columns: [Self.column("code", type: "varchar", length: 20, collation: Self.serverDefault)],
            databaseCollation: nil
        )
        #expect(ddl.contains("[code] VARCHAR(20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL"))
    }

    @Test("A collation that is not a collation name fails the statement")
    func collationThatIsNotANameIsRefused() {
        let text = "Latin1_General_CS_AS NOT NULL, [x] INT"
        #expect(throws: MSSQLDefinitionRefusal.collation("code", text)) {
            try Self.statement(columns: [Self.column("code", type: "varchar", length: 20, collation: text)])
        }
    }

    @Test("A column read from the catalog writes the collation, computed expression and identity it was read with")
    func catalogRowsRoundTrip() throws {
        let rows: [[String?]] = [
            ["id", "bigint", nil, "19", "0", "NO", nil, "1", "1", "0", "0", nil, nil, nil, "100", "10"],
            ["code", "nvarchar", "40", nil, nil, "YES", nil, "0", "0", "0", "0", "Latin1_General_CS_AS", nil, nil, nil, nil],
            ["twice", "bigint", nil, "19", "0", "NO", nil, "0", "0", "1", "0", nil, "([id]*(2))", "1", nil, nil],
        ]
        let ddl = try Self.statement(columns: rows.compactMap(MSSQLSchemaQueries.parseColumnRow))
        #expect(ddl == """
            CREATE TABLE [dbo].[t] (
                [id] BIGINT IDENTITY(100,10) NOT NULL,
                [code] NVARCHAR(40) COLLATE Latin1_General_CS_AS NULL,
                [twice] AS ([id]*(2)) PERSISTED NOT NULL
            );
            """)
    }
}
