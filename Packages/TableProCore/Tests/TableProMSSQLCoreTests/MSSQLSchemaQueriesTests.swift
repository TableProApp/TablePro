import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLSchemaQueriesTests {
    @Test func testEscapeHandlesSingleQuote() {
        #expect(MSSQLSchemaQueries.escape("O'Brien") == "O''Brien")
        #expect(MSSQLSchemaQueries.escape("plain") == "plain")
    }

    @Test func testEscapeBracketHandlesClosingBracket() {
        #expect(MSSQLSchemaQueries.escapeBracket("weird]name") == "weird]]name")
    }

    /// A name `sp_rename` accepted verbatim must not close its brackets early and start a new batch.
    @Test func testEscapeBracketDoublesABracketBeforeACombiningMark() {
        #expect(MSSQLSchemaQueries.escapeBracket("v]\u{0301}\nGO") == "v]]\u{0301}\nGO")
        #expect(MSSQLSchemaQueries.bracketed(schema: "dbo", table: "v]\u{0301}") == "[dbo].[v]]\u{0301}]")
    }

    @Test func testBracketedComposesIdentifier() {
        #expect(MSSQLSchemaQueries.bracketed(schema: "dbo", table: "Users") == "[dbo].[Users]")
        #expect(MSSQLSchemaQueries.bracketed(schema: "weird]", table: "x") == "[weird]]].[x]")
    }

    /// Unqualified, both views describe the database the connection is using, so every name got that database's
    /// numbers. Measured on SQL Server 2022 connected to AppDb: msdb reported 16 MB and 2 tables instead of 145.
    @Test func testDatabaseMetadataReadsTheNamedDatabasesCatalog() {
        let sql = MSSQLSchemaQueries.databaseMetadata(database: "msdb")

        #expect(sql.contains("FROM [msdb].sys.database_files"))
        #expect(sql.contains("FROM [msdb].sys.tables"))
        #expect(!sql.contains(" sys.database_files"))
        #expect(!sql.contains(" sys.tables"))
    }

    @Test func testDatabaseMetadataEscapesAClosingBracketInTheName() {
        let sql = MSSQLSchemaQueries.databaseMetadata(database: "we]ird")

        #expect(sql.contains("FROM [we]]ird].sys.database_files"))
        #expect(sql.contains("FROM [we]]ird].sys.tables"))
    }

    /// The session runs with ANSI_WARNINGS off, so an int sum over a 2 GB database overflowed to NULL.
    @Test func testSizesAreSummedAsBigintBytes() {
        #expect(MSSQLSchemaQueries.databaseMetadata(database: "AppDb").contains("SUM(CAST(size AS bigint)) * 8192"))
        #expect(MSSQLSchemaQueries.allDatabaseSizes.contains("SUM(CAST(mf.size AS bigint)) * 8192"))
        #expect(MSSQLSchemaQueries.allDatabaseSizes.contains("LEFT JOIN sys.master_files"))
    }

    @Test func testTablesQueryEscapesSchema() {
        let sql = MSSQLSchemaQueries.tables(schema: "O'Brien")
        #expect(sql.contains("N'O''Brien'"))
        #expect(sql.contains("INFORMATION_SCHEMA.TABLES"))
        #expect(sql.contains("'BASE TABLE'"))
        #expect(sql.contains("'VIEW'"))
    }

    @Test func testOneSchemaListingIsFilteredByTheSchemaAlone() {
        let sql = MSSQLSchemaQueries.tables(in: .schema("sales"))
        #expect(sql == MSSQLSchemaQueries.tables(schema: "sales"))
        #expect(sql.contains("WHERE t.TABLE_SCHEMA = N'sales'"))
        #expect(sql.hasPrefix("SELECT t.TABLE_NAME, t.TABLE_TYPE\n"))
        #expect(sql.hasSuffix("ORDER BY t.TABLE_NAME"))
        #expect(!sql.contains("INFORMATION_SCHEMA.SCHEMATA"))
    }

    /// The all-schema listing is filtered by the schema list query itself, so a table is listed exactly when its schema
    /// is one `fetchSchemas()` returns. SQL Server rejects an `ORDER BY` inside that subquery, which is why the list is
    /// split from its ordering.
    @Test func testAllSchemaListingIsFilteredByTheSchemaListQuery() {
        let sql = MSSQLSchemaQueries.tables(in: .allSchemas)
        #expect(sql.contains("WHERE t.TABLE_SCHEMA IN (\n\(MSSQLSchemaQueries.listedSchemaNames)\n)"))
        #expect(!sql.contains("ORDER BY SCHEMA_NAME"))
        #expect(sql.hasPrefix("SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_SCHEMA\n"))
        #expect(sql.contains("AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')"))
        #expect(sql.hasSuffix("ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME"))
    }

    @Test func testSchemaSetListingIsFilteredByTheNamedSchemasAlone() {
        let sql = MSSQLSchemaQueries.tables(in: .schemas(["sales", "dbo"]))
        #expect(sql.contains("WHERE t.TABLE_SCHEMA IN (N'sales', N'dbo')\n"))
        #expect(!sql.contains("INFORMATION_SCHEMA.SCHEMATA"))
        #expect(sql.hasPrefix("SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_SCHEMA\n"))
        #expect(sql.contains("AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')"))
        #expect(sql.hasSuffix("ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME"))
    }

    @Test func testSchemaSetListingQuotesEachName() {
        let sql = MSSQLSchemaQueries.tables(in: .schemas(["O'Brien", "日本"]))
        #expect(sql.contains("t.TABLE_SCHEMA IN (N'O''Brien', N'日本')"))
        #expect(!sql.contains("N'O'Brien'"))
    }

    @Test func testEmptySchemaSetListingMatchesNothing() {
        let sql = MSSQLSchemaQueries.tables(in: .schemas([]))
        #expect(sql.contains("WHERE 1 = 0\n"))
        #expect(!(sql.contains("IN ()")))
    }

    @Test func testSchemaListIsTheListedSchemasInOrder() {
        #expect(MSSQLSchemaQueries.schemas == MSSQLSchemaQueries.listedSchemaNames + "\nORDER BY SCHEMA_NAME")
        #expect(!MSSQLSchemaQueries.listedSchemaNames.contains("ORDER BY"))
    }

    @Test func testParseTableRowReadsTheSchemaColumnWhenPresent() {
        #expect(MSSQLSchemaQueries.parseTableRow(["orders", "BASE TABLE", "sales"]) == MSSQLTableRow(name: "orders", isView: false, schema: "sales"))
        #expect(MSSQLSchemaQueries.parseTableRow(["orders", "BASE TABLE"])?.schema == nil)
    }

    @Test func testColumnsQueryIncludesIdentityAndPrimaryKey() {
        let sql = MSSQLSchemaQueries.columns(schema: "dbo", table: "Users")
        #expect(sql.contains("IsIdentity"))
        #expect(sql.contains("PRIMARY KEY"))
        #expect(sql.contains("N'Users'"))
        #expect(sql.contains("N'dbo'"))
    }

    @Test func testColumnsQueryQuotesBothNamesBeforeResolvingTheObject() {
        let sql = MSSQLSchemaQueries.columns(schema: "x.y", table: "a.b")
        #expect(sql.contains("OBJECT_ID(QUOTENAME(c.TABLE_SCHEMA) + '.' + QUOTENAME(c.TABLE_NAME))"))
        #expect(!(sql.contains("OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME)")))
    }

    @Test func testColumnsQueryReportsRowversionAndPeriodColumnsAsServerGenerated() {
        let sql = MSSQLSchemaQueries.columns(schema: "dbo", table: "Users")
        #expect(sql.contains("WHEN c.DATA_TYPE = 'timestamp' THEN 1"))
        #expect(sql.contains("'GeneratedAlwaysType') > 0 THEN 1"))
        #expect(sql.contains("AS IS_SERVER_GENERATED"))
    }

    @Test func testAllColumnsQueryCarriesTheTableNameAfterTheParsedColumns() {
        let sql = MSSQLSchemaQueries.allColumns(schema: "dbo")
        #expect(sql.contains("AS IS_SERVER_GENERATED,\n    c.TABLE_NAME"))
        #expect(sql.contains("c.TABLE_SCHEMA = N'dbo'"))
        #expect(MSSQLSchemaQueries.allColumnsTableNameIndex == 11)
    }

    @Test func testParseColumnRowReadsServerGeneratedColumns() {
        let rowversion: [String?] = ["RV", "timestamp", nil, nil, nil, "NO", nil, "0", "0", "0", "1"]
        #expect(MSSQLSchemaQueries.parseColumnRow(rowversion)?.isServerGenerated == true)
        #expect(MSSQLSchemaQueries.parseColumnRow(rowversion)?.isGenerated == true)

        let computed: [String?] = ["Doubled", "int", nil, "10", "0", "YES", nil, "0", "0", "1", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(computed)?.isGenerated == true)
        #expect(MSSQLSchemaQueries.parseColumnRow(computed)?.isServerGenerated == false)

        let plain: [String?] = ["Name", "nvarchar", "50", nil, nil, "YES", nil, "0", "0", "0", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(plain)?.isGenerated == false)
    }

    @Test func testIndexesQueryUsesBracketedIdentifier() {
        let sql = MSSQLSchemaQueries.indexes(schema: "dbo", table: "Users")
        #expect(sql.contains("OBJECT_ID(N'[dbo].[Users]')"))
        #expect(sql.contains("sys.indexes"))
    }

    @Test func testForeignKeysQueryFiltersByTableAndSchema() {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: "dbo", table: "Orders")
        #expect(sql.contains("sys.foreign_keys"))
        #expect(sql.contains("N'Orders'"))
        #expect(sql.contains("N'dbo'"))
    }

    @Test func testForeignKeysQuerySelectsReferencedSchema() {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: "dbo", table: "Orders")
        #expect(sql.contains("sr.name AS ref_schema"))
        #expect(sql.contains("JOIN sys.schemas sr ON tr.schema_id = sr.schema_id"))
    }

    @Test func testParseTableRowDetectsView() {
        let row: [String?] = ["v_active_users", "VIEW"]
        #expect(MSSQLSchemaQueries.parseTableRow(row) == MSSQLTableRow(name: "v_active_users", isView: true))
    }

    @Test func testParseTableRowDefaultsToTable() {
        let row: [String?] = ["users", "BASE TABLE"]
        #expect(MSSQLSchemaQueries.parseTableRow(row) == MSSQLTableRow(name: "users", isView: false))
    }

    @Test func testParseTableRowRejectsMissingName() {
        #expect(MSSQLSchemaQueries.parseTableRow([nil, "BASE TABLE"]) == nil)
    }

    @Test func testParseColumnRowExtractsAllFields() {
        let row: [String?] = ["id", "int", nil, "10", "0", "NO", nil, "1", "1"]
        let parsed = MSSQLSchemaQueries.parseColumnRow(row)
        #expect(parsed?.name == "id")
        #expect(parsed?.dataType == "int")
        #expect(parsed?.isNullable == false)
        #expect(parsed?.isIdentity == true)
        #expect(parsed?.isPrimaryKey == true)
    }

    @Test func testColumnDisplayTypeForFixedSizeOmitsLength() {
        let row: [String?] = ["id", "int", "4", nil, nil, "NO", nil, "0", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(row)?.displayType == "int")
    }

    @Test func testColumnDisplayTypeForVarcharIncludesLength() {
        let row: [String?] = ["name", "nvarchar", "100", nil, nil, "YES", nil, "0", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(row)?.displayType == "nvarchar(100)")
    }

    @Test func testColumnDisplayTypeForMaxLengthRendersMax() {
        let row: [String?] = ["body", "varchar", "-1", nil, nil, "YES", nil, "0", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(row)?.displayType == "varchar(max)")
    }

    @Test func testColumnDisplayTypeForDecimalIncludesPrecisionScale() {
        let row: [String?] = ["amount", "decimal", nil, "18", "2", "NO", nil, "0", "0"]
        #expect(MSSQLSchemaQueries.parseColumnRow(row)?.displayType == "decimal(18,2)")
    }

    @Test func testParseIndexRowExtractsFlags() {
        let row: [String?] = ["IX_users_email", "1", "0", "email"]
        let parsed = MSSQLSchemaQueries.parseIndexRow(row)
        #expect(parsed?.name == "IX_users_email")
        #expect(parsed?.isUnique == true)
        #expect(parsed?.isPrimary == false)
        #expect(parsed?.columnName == "email")
    }

    @Test func testParseIndexRowRejectsMissingColumn() {
        #expect(MSSQLSchemaQueries.parseIndexRow(["IX_x", "0", "0", nil]) == nil)
    }

    @Test func testParseForeignKeyRowExtractsAll() {
        let row: [String?] = ["FK_orders_users", "user_id", "users", "id", "sales"]
        let parsed = MSSQLSchemaQueries.parseForeignKeyRow(row)
        #expect(parsed?.constraintName == "FK_orders_users")
        #expect(parsed?.columnName == "user_id")
        #expect(parsed?.referencedTable == "users")
        #expect(parsed?.referencedColumn == "id")
        #expect(parsed?.referencedSchema == "sales")
    }

    @Test func testParseForeignKeyRowWithoutReferencedSchema() {
        let row: [String?] = ["FK_orders_users", "user_id", "users", "id"]
        #expect(MSSQLSchemaQueries.parseForeignKeyRow(row)?.referencedSchema == nil)
    }

    @Test func testQualifiedNamePrefixesSchema() {
        #expect(MSSQLSchemaQueries.qualifiedName(schema: "sales", table: "routeCache") == "[sales].[routeCache]")
    }

    @Test func testQualifiedNameOmitsSchemaWhenNilOrEmpty() {
        #expect(MSSQLSchemaQueries.qualifiedName(schema: nil, table: "routeCache") == "[routeCache]")
        #expect(MSSQLSchemaQueries.qualifiedName(schema: "", table: "routeCache") == "[routeCache]")
    }

    @Test func testBrowseQualifiesNonDefaultSchema() {
        let sql = MSSQLSchemaQueries.browse(
            schema: "sales", table: "routeCache",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        #expect(sql == "SELECT * FROM [sales].[routeCache] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY")
    }

    @Test func testBrowseWithoutSchemaStaysUnqualified() {
        let sql = MSSQLSchemaQueries.browse(
            schema: nil, table: "routeCache",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 10, limit: 50
        )
        #expect(sql == "SELECT * FROM [routeCache] ORDER BY (SELECT NULL) OFFSET 10 ROWS FETCH NEXT 50 ROWS ONLY")
    }

    @Test func testFilteredQualifiesSchemaAndAppendsWhere() {
        let sql = MSSQLSchemaQueries.filtered(
            schema: "sales", table: "routeCache", whereClause: "[id] = 1",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        #expect(sql == "SELECT * FROM [sales].[routeCache] WHERE [id] = 1 ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY")
    }

    @Test func testFilteredOmitsWhenWhereClauseEmpty() {
        let sql = MSSQLSchemaQueries.filtered(
            schema: "sales", table: "routeCache", whereClause: "",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        #expect(sql == "SELECT * FROM [sales].[routeCache] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY")
    }

    @Test func testCatalogPredicatesSurviveANonAsciiName() {
        let columns = MSSQLSchemaQueries.columns(schema: "dbo", table: "顧客テーブル")
        #expect(columns.contains("N'顧客テーブル'"))
        #expect(!columns.contains("= '顧客テーブル'"))

        let indexes = MSSQLSchemaQueries.indexes(schema: "dbo", table: "顧客テーブル")
        #expect(indexes.contains("OBJECT_ID(N'[dbo].[顧客テーブル]')"))

        let foreignKeys = MSSQLSchemaQueries.foreignKeys(schema: "スキーマ", table: "顧客テーブル")
        #expect(foreignKeys.contains("N'顧客テーブル'"))
        #expect(foreignKeys.contains("N'スキーマ'"))
    }

    @Test func testFixedCatalogConstantsStayUnprefixed() {
        let tables = MSSQLSchemaQueries.tables(schema: "dbo")
        #expect(tables.contains("IN ('BASE TABLE', 'VIEW')"))
        #expect(MSSQLSchemaQueries.columns(schema: "dbo", table: "t").contains("= 'PRIMARY KEY'"))
        #expect(MSSQLSchemaQueries.schemas.contains("'information_schema'"))
    }
}
