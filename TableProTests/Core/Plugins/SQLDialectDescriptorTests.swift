//
//  SQLDialectDescriptorTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLDialectDescriptorTests: XCTestCase {
    // MARK: - SQLDialectDescriptor Creation

    func testDescriptorCreation() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM", "WHERE"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "VARCHAR"]
        )

        XCTAssertEqual(descriptor.identifierQuote, "`")
        XCTAssertEqual(descriptor.identifierClosingQuote, "`")
        XCTAssertEqual(descriptor.keywords, ["SELECT", "FROM", "WHERE"])
        XCTAssertEqual(descriptor.functions, ["COUNT", "SUM"])
        XCTAssertEqual(descriptor.dataTypes, ["INT", "VARCHAR"])
    }

    func testDescriptorWithEmptySets() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: []
        )

        XCTAssertEqual(descriptor.identifierQuote, "\"")
        XCTAssertEqual(descriptor.identifierClosingQuote, "\"")
        XCTAssertTrue(descriptor.keywords.isEmpty)
        XCTAssertTrue(descriptor.functions.isEmpty)
        XCTAssertTrue(descriptor.dataTypes.isEmpty)
    }

    func testDescriptorDefaultsBracketClosingQuote() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: []
        )

        XCTAssertEqual(descriptor.identifierClosingQuote, "]")
        XCTAssertEqual(descriptor.quoteIdentifier("name]part"), "[name]]part]")
    }

    func testDescriptorSupportsExplicitClosingQuote() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "<",
            identifierClosingQuote: ">",
            keywords: [],
            functions: [],
            dataTypes: []
        )

        XCTAssertEqual(descriptor.quoteIdentifier("a>b"), "<a>>b>")
    }

    func testDescriptorBuildsFilterSQLLiterals() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [],
            functions: [],
            dataTypes: [],
            booleanLiteralStyle: .numeric,
            likeEscapeStyle: .implicit
        )

        XCTAssertEqual(descriptor.sqlLiteral(for: "123"), "123")
        XCTAssertEqual(descriptor.sqlLiteral(for: "NULL"), "NULL")
        XCTAssertEqual(descriptor.sqlLiteral(for: "TRUE"), "1")
        XCTAssertEqual(descriptor.sqlLiteral(for: "O'Brien"), "'O''Brien'")
        XCTAssertEqual(
            descriptor.sqlLiteral(for: "NULL", interpretSpecialLiterals: false),
            "'NULL'"
        )
    }

    func testDescriptorEscapesLikeWildcardsByDialect() {
        let mysql = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .implicit
        )
        let postgresql = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit
        )

        XCTAssertEqual(mysql.escapeLikeWildcards("a_b%"), "a\\\\_b\\\\%")
        XCTAssertEqual(mysql.likeEscapeClause, "")
        XCTAssertEqual(postgresql.escapeLikeWildcards("a!b%"), "a!!b!%")
        XCTAssertEqual(postgresql.likeEscapeClause, " ESCAPE '!'")
    }

    func testPluginSQLFilterUsesDescriptorForNullEquality() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit
        )

        let equals = PluginSQLFilter.buildWhereClause(
            filters: [(column: "deleted_at", op: "=", value: "NULL")],
            logicMode: "and",
            dialect: descriptor,
            regexCondition: { _, _ in nil }
        )
        let notEquals = PluginSQLFilter.buildWhereClause(
            filters: [(column: "deleted_at", op: "!=", value: "NULL")],
            logicMode: "and",
            dialect: descriptor,
            regexCondition: { _, _ in nil }
        )

        XCTAssertEqual(equals, "\"deleted_at\" IS NULL")
        XCTAssertEqual(notEquals, "\"deleted_at\" IS NOT NULL")
    }

    func testPluginSQLFilterUsesDescriptorForLikeEscaping() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit
        )

        let result = PluginSQLFilter.buildWhereClause(
            filters: [(column: "name", op: "CONTAINS", value: "a_b%!x'")],
            logicMode: "and",
            dialect: descriptor,
            regexCondition: { _, _ in nil }
        )

        XCTAssertEqual(result, "\"name\" LIKE '%a!_b!%!!x''%' ESCAPE '!'")
    }

    func testPluginSQLFilterLegacyLikeEscapingDoesNotDoubleQuote() {
        let result = PluginSQLFilter.buildWhereClause(
            filters: [(column: "name", op: "CONTAINS", value: "O'Brien")],
            logicMode: "and",
            quoteIdentifier: { "\"\($0)\"" },
            escapeValue: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" },
            regexCondition: { _, _ in nil }
        )

        XCTAssertEqual(result, "\"name\" LIKE '%O''Brien%' ESCAPE '\\'")
    }

    func testPluginSQLFilterBuildsOffsetFetchBrowseQuery() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: .offsetFetch,
            offsetFetchOrderBy: "ORDER BY (SELECT NULL)"
        )

        let result = PluginSQLFilter.buildBrowseQuery(
            table: "users]archive",
            dialect: descriptor,
            sortColumns: [(columnIndex: 1, ascending: false)],
            columns: ["id", "name"],
            limit: 25,
            offset: 50
        )

        XCTAssertEqual(
            result,
            "SELECT * FROM [users]]archive] ORDER BY [name] DESC OFFSET 50 ROWS FETCH NEXT 25 ROWS ONLY"
        )
    }

    func testPluginSQLFilterBuildsFilteredOffsetFetchQueryWithDefaultOrder() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: [],
            paginationStyle: .offsetFetch,
            offsetFetchOrderBy: "ORDER BY (SELECT NULL)"
        )

        let result = PluginSQLFilter.buildFilteredQuery(
            table: "users",
            filters: [(column: "deleted_at", op: "=", value: "NULL")],
            logicMode: "and",
            dialect: descriptor,
            sortColumns: [],
            columns: ["id", "deleted_at"],
            limit: 10,
            offset: 0,
            regexCondition: { _, _ in nil }
        )

        XCTAssertEqual(
            result,
            "SELECT * FROM [users] WHERE [deleted_at] IS NULL ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY"
        )
    }

    func testPluginSQLFilterBuildsLimitQuery() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit,
            paginationStyle: .limit
        )

        let result = PluginSQLFilter.buildFilteredQuery(
            table: "users",
            filters: [(column: "name", op: "CONTAINS", value: "a_%")],
            logicMode: "and",
            dialect: descriptor,
            sortColumns: [(columnIndex: 0, ascending: true)],
            columns: ["id", "name"],
            limit: 10,
            offset: 5,
            regexCondition: { _, _ in nil }
        )

        XCTAssertEqual(
            result,
            "SELECT * FROM \"users\" WHERE \"name\" LIKE '%a!_!%%' ESCAPE '!' ORDER BY \"id\" ASC LIMIT 10 OFFSET 5"
        )
    }

    func testPluginSQLStatementBuilderPreservesMSSQLRules() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: []
        )
        let insert = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let delete = PluginRowChange(
            rowIndex: 1,
            type: .delete,
            cellChanges: [],
            originalRow: ["7", "Old"]
        )
        let update = PluginRowChange(
            rowIndex: 2,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Old", newValue: "New")
            ],
            originalRow: ["7", "Old"]
        )

        let result = PluginSQLStatementBuilder.generateStatements(
            table: "users]archive",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            changes: [insert, delete, update],
            insertedRowData: [0: ["99", "Alice"]],
            deletedRowIndices: [1],
            insertedRowIndices: [0],
            quoteIdentifier: descriptor.quoteIdentifier,
            insertDefaultStrategy: .omitColumn,
            includeInsertedColumn: { $0 != "id" },
            whereColumnStrategy: .primaryKeyOrAll,
            collectDeletesLast: true,
            singleRowUpdatePrefixWhenNoPrimaryKey: "TOP (1) ",
            singleRowDeletePrefixWhenNoPrimaryKey: "TOP (1) "
        )

        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0].statement, "INSERT INTO [users]]archive] ([name]) VALUES (?)")
        XCTAssertEqual(result?[0].parameters, ["Alice"])
        XCTAssertEqual(result?[1].statement, "UPDATE [users]]archive] SET [name] = ? WHERE [id] = ?")
        XCTAssertEqual(result?[1].parameters, ["New", "7"])
        XCTAssertEqual(result?[2].statement, "DELETE FROM [users]]archive] WHERE [id] = ?")
        XCTAssertEqual(result?[2].parameters, ["7"])
    }

    func testPluginSQLStatementBuilderAddsMSSQLTopWhenNoPrimaryKey() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: [],
            functions: [],
            dataTypes: []
        )
        let update = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Old", newValue: "New")
            ],
            originalRow: ["7", "Old"]
        )
        let delete = PluginRowChange(
            rowIndex: 1,
            type: .delete,
            cellChanges: [],
            originalRow: ["8", .null]
        )

        let result = PluginSQLStatementBuilder.generateStatements(
            table: "users",
            columns: ["id", "name"],
            primaryKeyColumns: [],
            changes: [update, delete],
            insertedRowData: [:],
            deletedRowIndices: [1],
            insertedRowIndices: [],
            quoteIdentifier: descriptor.quoteIdentifier,
            insertDefaultStrategy: .omitColumn,
            whereColumnStrategy: .primaryKeyOrAll,
            collectDeletesLast: true,
            singleRowUpdatePrefixWhenNoPrimaryKey: "TOP (1) ",
            singleRowDeletePrefixWhenNoPrimaryKey: "TOP (1) "
        )

        XCTAssertEqual(
            result?[0].statement,
            "UPDATE TOP (1) [users] SET [name] = ? WHERE [id] = ? AND [name] = ?"
        )
        XCTAssertEqual(result?[0].parameters, ["New", "7", "Old"])
        XCTAssertEqual(result?[1].statement, "DELETE TOP (1) FROM [users] WHERE [id] = ? AND [name] IS NULL")
        XCTAssertEqual(result?[1].parameters, ["8"])
    }

    func testPluginSQLStatementBuilderPreservesOracleRules() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: []
        )
        let insert = PluginRowChange(
            rowIndex: 0,
            type: .insert,
            cellChanges: [],
            originalRow: nil
        )
        let update = PluginRowChange(
            rowIndex: 1,
            type: .update,
            cellChanges: [
                (columnIndex: 1, columnName: "name", oldValue: "Old", newValue: "New")
            ],
            originalRow: ["7", "Old"]
        )
        let delete = PluginRowChange(
            rowIndex: 2,
            type: .delete,
            cellChanges: [],
            originalRow: ["8", .null]
        )

        let result = PluginSQLStatementBuilder.generateStatements(
            table: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            changes: [insert, update, delete],
            insertedRowData: [0: ["__DEFAULT__", "Alice"]],
            deletedRowIndices: [2],
            insertedRowIndices: [0],
            quoteIdentifier: descriptor.quoteIdentifier,
            insertDefaultStrategy: .useDefaultKeyword,
            whereColumnStrategy: .allColumns,
            updateWhereSuffix: " AND ROWNUM = 1",
            deleteWhereSuffix: " AND ROWNUM = 1"
        )

        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[0].statement, "INSERT INTO \"users\" (\"id\", \"name\") VALUES (DEFAULT, ?)")
        XCTAssertEqual(result?[0].parameters, ["Alice"])
        XCTAssertEqual(
            result?[1].statement,
            "UPDATE \"users\" SET \"name\" = ? WHERE \"id\" = ? AND \"name\" = ? AND ROWNUM = 1"
        )
        XCTAssertEqual(result?[1].parameters, ["New", "7", "Old"])
        XCTAssertEqual(
            result?[2].statement,
            "DELETE FROM \"users\" WHERE \"id\" = ? AND \"name\" IS NULL AND ROWNUM = 1"
        )
        XCTAssertEqual(result?[2].parameters, ["8"])
    }

    func testPluginSQLDDLBuilderFormatsDefaultValues() {
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "'", with: "''")
        }

        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "CURRENT_TIMESTAMP",
                rawUppercaseValues: ["NULL", "CURRENT_TIMESTAMP"],
                escapeStringLiteral: escape
            ),
            "CURRENT_TIMESTAMP"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "'already quoted'",
                rawUppercaseValues: [],
                escapeStringLiteral: escape
            ),
            "'already quoted'"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "12.5",
                rawUppercaseValues: [],
                escapeStringLiteral: escape
            ),
            "12.5"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "O'Brien",
                rawUppercaseValues: [],
                escapeStringLiteral: escape
            ),
            "'O''Brien'"
        )
    }

    func testPluginSQLDDLBuilderSupportsDialectSpecificRawDefaults() {
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "'", with: "''")
        }

        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "'users_id_seq'::regclass",
                rawUppercaseValues: [],
                rawUppercaseSuffixes: ["::REGCLASS"],
                escapeStringLiteral: escape
            ),
            "'users_id_seq'::regclass"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "(newid())",
                rawUppercaseValues: [],
                allowsParenthesizedExpressions: true,
                escapeStringLiteral: escape
            ),
            "(newid())"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.defaultValue(
                "(newid())",
                rawUppercaseValues: [],
                escapeStringLiteral: escape
            ),
            "'(newid())'"
        )
    }

    func testPluginSQLDDLBuilderBuildsColumnDefinitionWithPostTypeClause() {
        let column = PluginColumnDefinition(
            name: "user]id",
            dataType: "INT",
            isNullable: false,
            defaultValue: "42",
            isPrimaryKey: true,
            autoIncrement: true
        )

        let result = PluginSQLDDLBuilder.columnDefinition(
            column,
            inlinePrimaryKey: true,
            quoteIdentifier: { "[\($0.replacingOccurrences(of: "]", with: "]]"))]" },
            formatDefaultValue: { $0 },
            postDataTypeSQL: { $0.autoIncrement ? "IDENTITY(1,1)" : nil }
        )

        XCTAssertEqual(result, "[user]]id] INT IDENTITY(1,1) NOT NULL DEFAULT 42 PRIMARY KEY")
    }

    func testPluginSQLDDLBuilderCanTransformAutoIncrementType() {
        let column = PluginColumnDefinition(
            name: "id",
            dataType: "BIGINT",
            isNullable: false,
            defaultValue: "nextval('users_id_seq'::regclass)",
            isPrimaryKey: true,
            autoIncrement: true
        )

        let result = PluginSQLDDLBuilder.columnDefinition(
            column,
            inlinePrimaryKey: true,
            quoteIdentifier: { "\"\($0)\"" },
            formatDefaultValue: { $0 },
            dataTypeSQL: { column in
                guard column.autoIncrement else { return column.dataType }
                return column.dataType.uppercased() == "BIGINT" ? "BIGSERIAL" : "SERIAL"
            },
            suppressNullability: { $0.autoIncrement }
        )

        XCTAssertEqual(result, "\"id\" BIGSERIAL DEFAULT nextval('users_id_seq'::regclass) PRIMARY KEY")
    }

    func testPluginSQLDDLBuilderSupportsDefaultBeforeNullability() {
        let column = PluginColumnDefinition(
            name: "created_at",
            dataType: "timestamp",
            isNullable: false,
            defaultValue: "SYSDATE"
        )

        let result = PluginSQLDDLBuilder.columnDefinition(
            column,
            inlinePrimaryKey: false,
            quoteIdentifier: { "\"\($0)\"" },
            formatDefaultValue: { $0 },
            dataTypeSQL: { $0.dataType.uppercased() },
            emitsNullableKeyword: false,
            defaultClausePosition: .beforeNullability
        )

        XCTAssertEqual(result, "\"created_at\" TIMESTAMP DEFAULT SYSDATE NOT NULL")
    }

    func testPluginSQLDDLBuilderSupportsPrimaryKeyAfterDataType() {
        let column = PluginColumnDefinition(
            name: "id",
            dataType: "INTEGER",
            isNullable: false,
            defaultValue: "1",
            isPrimaryKey: true,
            autoIncrement: true
        )

        let result = PluginSQLDDLBuilder.columnDefinition(
            column,
            inlinePrimaryKey: true,
            quoteIdentifier: { "\"\($0)\"" },
            formatDefaultValue: { $0 },
            emitsNullableKeyword: false,
            primaryKeyClausePosition: .afterDataType,
            postPrimaryKeySQL: { $0.autoIncrement ? "AUTOINCREMENT" : nil }
        )

        XCTAssertEqual(result, "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL DEFAULT 1")
    }

    func testPluginSQLDDLBuilderBuildsCreateIndexDefinition() {
        let index = PluginIndexDefinition(
            name: "idx_users_email",
            columns: ["email"],
            isUnique: true,
            whereClause: "email IS NOT NULL"
        )

        let result = PluginSQLDDLBuilder.createIndexDefinition(
            index,
            quoteIdentifier: { "\"\($0)\"" },
            tableSQL: "\"users\"",
            includeWhereClause: false
        )

        XCTAssertEqual(result, "CREATE UNIQUE INDEX \"idx_users_email\" ON \"users\" (\"email\")")
    }

    func testPluginSQLDDLBuilderBuildsIndexMethodAndWhereClause() {
        let index = PluginIndexDefinition(
            name: "idx_users_search",
            columns: ["search_vector"],
            indexType: "GIN",
            whereClause: "search_vector IS NOT NULL"
        )

        let result = PluginSQLDDLBuilder.createIndexDefinition(
            index,
            quoteIdentifier: { "\"\($0)\"" },
            tableSQL: "\"public\".\"users\"",
            indexMethodSQL: { index in
                guard let type = index.indexType?.lowercased() else { return nil }
                return "USING \(type)"
            },
            includeWhereClause: true
        )

        XCTAssertEqual(
            result,
            "CREATE INDEX \"idx_users_search\" ON \"public\".\"users\" USING gin (\"search_vector\") WHERE search_vector IS NOT NULL"
        )
    }

    func testPluginSQLDDLBuilderBuildsIndexColumnListWithCustomColumnSQL() {
        let index = PluginIndexDefinition(
            name: "idx_users_email_name",
            columns: ["email", "name"],
            columnPrefixes: ["email": 191]
        )

        let result = PluginSQLDDLBuilder.indexColumnList(
            index,
            quoteIdentifier: { "`\($0)`" },
            formatColumnSQL: { column in
                let quoted = "`\(column)`"
                if let prefix = index.columnPrefixes?[column] {
                    return "\(quoted)(\(prefix))"
                }
                return quoted
            }
        )

        XCTAssertEqual(result, "`email`(191), `name`")
    }

    func testPluginSQLDDLBuilderBuildsIndexDefinitionFragment() {
        let index = PluginIndexDefinition(
            name: "idx_users_email",
            columns: ["email"],
            indexType: "BTREE",
            columnPrefixes: ["email": 191],
            whereClause: "email IS NOT NULL"
        )

        let result = PluginSQLDDLBuilder.indexDefinitionFragment(
            index,
            quoteIdentifier: { "`\($0)`" },
            indexKindSQL: { _ in "INDEX" },
            indexMethodSQL: { index in
                index.indexType.map { "USING \($0.uppercased())" }
            },
            formatColumnSQL: { column in
                let quoted = "`\(column)`"
                if let prefix = index.columnPrefixes?[column] {
                    return "\(quoted)(\(prefix))"
                }
                return quoted
            },
            includeWhereClause: false
        )

        XCTAssertEqual(result, "INDEX `idx_users_email` (`email`(191)) USING BTREE")
    }

    func testPluginSQLDDLBuilderBuildsDropIndexDefinition() {
        XCTAssertEqual(
            PluginSQLDDLBuilder.dropIndexDefinition(
                indexName: "idx_users_email",
                quoteIdentifier: { "`\($0)`" },
                ifExists: true
            ),
            "DROP INDEX IF EXISTS `idx_users_email`"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.dropIndexDefinition(
                indexName: "idx_users_email",
                quoteIdentifier: { "[\($0)]" },
                tableSQL: "[dbo].[users]"
            ),
            "DROP INDEX [idx_users_email] ON [dbo].[users]"
        )
    }

    func testPluginSQLDDLBuilderBuildsAlterTableDropObjectDefinition() {
        let result = PluginSQLDDLBuilder.alterTableDropObjectDefinition(
            tableSQL: "`users`",
            objectKind: "FOREIGN KEY",
            objectName: "fk_users_roles",
            quoteIdentifier: { "`\($0)`" }
        )

        XCTAssertEqual(result, "ALTER TABLE `users` DROP FOREIGN KEY `fk_users_roles`")
    }

    func testPluginSQLDDLBuilderBuildsAlterTableAddColumnDefinition() {
        XCTAssertEqual(
            PluginSQLDDLBuilder.alterTableAddColumnDefinition(
                tableSQL: "\"users\"",
                columnSQL: "\"email\" TEXT NOT NULL"
            ),
            "ALTER TABLE \"users\" ADD COLUMN \"email\" TEXT NOT NULL"
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.alterTableAddColumnDefinition(
                tableSQL: "[dbo].[users]",
                columnSQL: "[email] NVARCHAR(255)",
                addKeyword: "ADD"
            ),
            "ALTER TABLE [dbo].[users] ADD [email] NVARCHAR(255)"
        )
    }

    func testPluginSQLDDLBuilderBuildsAlterTableDropColumnDefinition() {
        XCTAssertEqual(
            PluginSQLDDLBuilder.alterTableDropColumnDefinition(
                tableSQL: "\"users\"",
                columnName: "email",
                quoteIdentifier: { "\"\($0)\"" }
            ),
            "ALTER TABLE \"users\" DROP COLUMN \"email\""
        )
        XCTAssertEqual(
            PluginSQLDDLBuilder.alterTableDropColumnDefinition(
                tableSQL: "\"users\"",
                columnName: "email",
                quoteIdentifier: { "\"\($0)\"" },
                dropKeyword: "DROP"
            ),
            "ALTER TABLE \"users\" DROP \"email\""
        )
    }

    func testPluginSQLDDLBuilderBuildsAlterTableRenameColumnDefinition() {
        let result = PluginSQLDDLBuilder.alterTableRenameColumnDefinition(
            tableSQL: "`users`",
            oldColumnName: "email",
            newColumnName: "primary_email",
            quoteIdentifier: { "`\($0)`" }
        )

        XCTAssertEqual(result, "ALTER TABLE `users` RENAME COLUMN `email` TO `primary_email`")
    }

    func testPluginSQLDDLBuilderBuildsPrimaryKeyColumnList() {
        let result = PluginSQLDDLBuilder.primaryKeyColumnList(
            ["id", "tenant_id"],
            quoteIdentifier: { "[\($0)]" }
        )

        XCTAssertEqual(result, "[id], [tenant_id]")
    }

    func testPluginSQLDDLBuilderBuildsModifyPrimaryKeyDefinitions() {
        let result = PluginSQLDDLBuilder.modifyPrimaryKeyDefinitions(
            tableSQL: "\"users\"",
            oldColumns: ["id"],
            newColumns: ["id", "tenant_id"],
            constraintName: "users_pkey",
            quoteIdentifier: { "\"\($0)\"" }
        )

        XCTAssertEqual(
            result,
            [
                "ALTER TABLE \"users\" DROP CONSTRAINT \"users_pkey\"",
                "ALTER TABLE \"users\" ADD PRIMARY KEY (\"id\", \"tenant_id\")"
            ]
        )
    }

    func testPluginSQLDDLBuilderBuildsDialectSpecificPrimaryKeyDefinitions() {
        let mysql = PluginSQLDDLBuilder.modifyPrimaryKeyDefinitions(
            tableSQL: "`users`",
            oldColumns: ["id"],
            newColumns: ["id"],
            constraintName: nil,
            quoteIdentifier: { "`\($0)`" },
            dropPrimaryKeyClauseSQL: "DROP PRIMARY KEY"
        )
        XCTAssertEqual(
            mysql,
            [
                "ALTER TABLE `users` DROP PRIMARY KEY",
                "ALTER TABLE `users` ADD PRIMARY KEY (`id`)"
            ]
        )

        let mssql = PluginSQLDDLBuilder.modifyPrimaryKeyDefinitions(
            tableSQL: "[dbo].[users]",
            oldColumns: [],
            newColumns: ["id"],
            constraintName: nil,
            quoteIdentifier: { "[\($0)]" },
            addConstraintNameSQL: "[PK_users]"
        )
        XCTAssertEqual(
            mssql,
            ["ALTER TABLE [dbo].[users] ADD CONSTRAINT [PK_users] PRIMARY KEY ([id])"]
        )

        XCTAssertNil(
            PluginSQLDDLBuilder.modifyPrimaryKeyDefinitions(
                tableSQL: "\"users\"",
                oldColumns: [],
                newColumns: [],
                constraintName: nil,
                quoteIdentifier: { "\"\($0)\"" }
            )
        )
    }

    func testPluginSQLDDLBuilderBuildsForeignKeyWithoutConstraintName() {
        let foreignKey = PluginForeignKeyDefinition(
            name: "fk_orders_users",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: "CASCADE",
            onUpdate: "SET NULL"
        )

        let result = PluginSQLDDLBuilder.foreignKeyDefinition(
            foreignKey,
            quoteIdentifier: { "\"\($0)\"" },
            includeConstraintName: false
        )

        XCTAssertEqual(
            result,
            "FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE ON UPDATE SET NULL"
        )
    }

    func testPluginSQLDDLBuilderBuildsSchemaQualifiedForeignKeyAndNormalizesActions() {
        let foreignKey = PluginForeignKeyDefinition(
            name: "fk_users_roles",
            columns: ["role_id"],
            referencedTable: "roles",
            referencedColumns: ["id"],
            onDelete: "cascade",
            onUpdate: "restrict",
            referencedSchema: "auth"
        )

        let result = PluginSQLDDLBuilder.foreignKeyDefinition(
            foreignKey,
            quoteIdentifier: { "`\($0)`" },
            referencedTableSQL: { foreignKey in
                let schema = foreignKey.referencedSchema.map { "`\($0)`." } ?? ""
                return "\(schema)`\(foreignKey.referencedTable)`"
            },
            normalizeAction: { $0.uppercased() }
        )

        XCTAssertEqual(
            result,
            "CONSTRAINT `fk_users_roles` FOREIGN KEY (`role_id`) REFERENCES `auth`.`roles` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT"
        )
    }

    func testPluginSQLDDLBuilderCanSuppressForeignKeyOnUpdate() {
        let foreignKey = PluginForeignKeyDefinition(
            name: "fk_orders_users",
            columns: ["user_id"],
            referencedTable: "users",
            referencedColumns: ["id"],
            onDelete: "CASCADE",
            onUpdate: "CASCADE"
        )

        let result = PluginSQLDDLBuilder.foreignKeyDefinition(
            foreignKey,
            quoteIdentifier: { "\"\($0)\"" },
            includeOnUpdate: false
        )

        XCTAssertEqual(
            result,
            "CONSTRAINT \"fk_orders_users\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\") ON DELETE CASCADE"
        )
    }

    // MARK: - PluginDialectAdapter

    @MainActor
    func testPluginDialectAdapterWrapsDescriptor() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: ["SELECT", "TOP", "NOLOCK"],
            functions: ["LEN", "GETDATE"],
            dataTypes: ["NVARCHAR", "BIT"]
        )

        let adapter = PluginDialectAdapter(descriptor: descriptor)

        XCTAssertEqual(adapter.identifierQuote, "[")
        XCTAssertEqual(adapter.keywords, ["SELECT", "TOP", "NOLOCK"])
        XCTAssertEqual(adapter.functions, ["LEN", "GETDATE"])
        XCTAssertEqual(adapter.dataTypes, ["NVARCHAR", "BIT"])
    }

    @MainActor
    func testPluginDialectAdapterConformsToSQLDialectProvider() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "TEXT"]
        )

        let adapter: SQLDialectProvider = PluginDialectAdapter(descriptor: descriptor)

        XCTAssertTrue(adapter.isKeyword("SELECT"))
        XCTAssertTrue(adapter.isKeyword("select"))
        XCTAssertFalse(adapter.isKeyword("NONEXISTENT"))

        XCTAssertTrue(adapter.isFunction("COUNT"))
        XCTAssertTrue(adapter.isFunction("count"))
        XCTAssertFalse(adapter.isFunction("NONEXISTENT"))

        XCTAssertTrue(adapter.isDataType("INT"))
        XCTAssertTrue(adapter.isDataType("int"))
        XCTAssertFalse(adapter.isDataType("NONEXISTENT"))
    }
}
