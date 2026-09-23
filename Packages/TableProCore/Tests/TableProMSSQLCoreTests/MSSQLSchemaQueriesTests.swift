@testable import TableProMSSQLCore
import XCTest

final class MSSQLSchemaQueriesTests: XCTestCase {
    func testEscapeHandlesSingleQuote() {
        XCTAssertEqual(MSSQLSchemaQueries.escape("O'Brien"), "O''Brien")
        XCTAssertEqual(MSSQLSchemaQueries.escape("plain"), "plain")
    }

    func testEscapeBracketHandlesClosingBracket() {
        XCTAssertEqual(MSSQLSchemaQueries.escapeBracket("weird]name"), "weird]]name")
    }

    func testBracketedComposesIdentifier() {
        XCTAssertEqual(MSSQLSchemaQueries.bracketed(schema: "dbo", table: "Users"), "[dbo].[Users]")
        XCTAssertEqual(MSSQLSchemaQueries.bracketed(schema: "weird]", table: "x"), "[weird]]].[x]")
    }

    /// Unqualified, both views describe the database the connection is using, so every name got that database's
    /// numbers. Measured on SQL Server 2022 connected to AppDb: msdb reported 16 MB and 2 tables instead of 145.
    func testDatabaseMetadataReadsTheNamedDatabasesCatalog() {
        let sql = MSSQLSchemaQueries.databaseMetadata(database: "msdb")

        XCTAssertTrue(sql.contains("FROM [msdb].sys.database_files"))
        XCTAssertTrue(sql.contains("FROM [msdb].sys.tables"))
        XCTAssertFalse(sql.contains(" sys.database_files"))
        XCTAssertFalse(sql.contains(" sys.tables"))
    }

    func testDatabaseMetadataEscapesAClosingBracketInTheName() {
        let sql = MSSQLSchemaQueries.databaseMetadata(database: "we]ird")

        XCTAssertTrue(sql.contains("FROM [we]]ird].sys.database_files"))
        XCTAssertTrue(sql.contains("FROM [we]]ird].sys.tables"))
    }

    /// The session runs with ANSI_WARNINGS off, so an int sum over a 2 GB database overflowed to NULL.
    func testSizesAreSummedAsBigintBytes() {
        XCTAssertTrue(MSSQLSchemaQueries.databaseMetadata(database: "AppDb").contains("SUM(CAST(size AS bigint)) * 8192"))
        XCTAssertTrue(MSSQLSchemaQueries.allDatabaseSizes.contains("SUM(CAST(mf.size AS bigint)) * 8192"))
        XCTAssertTrue(MSSQLSchemaQueries.allDatabaseSizes.contains("LEFT JOIN sys.master_files"))
    }

    func testTablesQueryEscapesSchema() {
        let sql = MSSQLSchemaQueries.tables(schema: "O'Brien")
        XCTAssertTrue(sql.contains("N'O''Brien'"))
        XCTAssertTrue(sql.contains("INFORMATION_SCHEMA.TABLES"))
        XCTAssertTrue(sql.contains("'BASE TABLE'"))
        XCTAssertTrue(sql.contains("'VIEW'"))
    }

    func testOneSchemaListingIsFilteredByTheSchemaAlone() {
        let sql = MSSQLSchemaQueries.tables(in: .schema("sales"))
        XCTAssertEqual(sql, MSSQLSchemaQueries.tables(schema: "sales"))
        XCTAssertTrue(sql.contains("WHERE t.TABLE_SCHEMA = N'sales'"))
        XCTAssertTrue(sql.hasPrefix("SELECT t.TABLE_NAME, t.TABLE_TYPE\n"))
        XCTAssertTrue(sql.hasSuffix("ORDER BY t.TABLE_NAME"))
        XCTAssertFalse(sql.contains("INFORMATION_SCHEMA.SCHEMATA"))
    }

    /// The all-schema listing is filtered by the schema list query itself, so a table is listed exactly when its schema
    /// is one `fetchSchemas()` returns. SQL Server rejects an `ORDER BY` inside that subquery, which is why the list is
    /// split from its ordering.
    func testAllSchemaListingIsFilteredByTheSchemaListQuery() {
        let sql = MSSQLSchemaQueries.tables(in: .allSchemas)
        XCTAssertTrue(sql.contains("WHERE t.TABLE_SCHEMA IN (\n\(MSSQLSchemaQueries.listedSchemaNames)\n)"))
        XCTAssertFalse(sql.contains("ORDER BY SCHEMA_NAME"))
        XCTAssertTrue(sql.hasPrefix("SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_SCHEMA\n"))
        XCTAssertTrue(sql.contains("AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')"))
        XCTAssertTrue(sql.hasSuffix("ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME"))
    }

    func testSchemaListIsTheListedSchemasInOrder() {
        XCTAssertEqual(MSSQLSchemaQueries.schemas, MSSQLSchemaQueries.listedSchemaNames + "\nORDER BY SCHEMA_NAME")
        XCTAssertFalse(MSSQLSchemaQueries.listedSchemaNames.contains("ORDER BY"))
    }

    func testParseTableRowReadsTheSchemaColumnWhenPresent() {
        XCTAssertEqual(
            MSSQLSchemaQueries.parseTableRow(["orders", "BASE TABLE", "sales"]),
            MSSQLTableRow(name: "orders", isView: false, schema: "sales")
        )
        XCTAssertNil(MSSQLSchemaQueries.parseTableRow(["orders", "BASE TABLE"])?.schema)
    }

    func testColumnsQueryIncludesIdentityAndPrimaryKey() {
        let sql = MSSQLSchemaQueries.columns(schema: "dbo", table: "Users")
        XCTAssertTrue(sql.contains("IsIdentity"))
        XCTAssertTrue(sql.contains("PRIMARY KEY"))
        XCTAssertTrue(sql.contains("N'Users'"))
        XCTAssertTrue(sql.contains("N'dbo'"))
    }

    func testIndexesQueryUsesBracketedIdentifier() {
        let sql = MSSQLSchemaQueries.indexes(schema: "dbo", table: "Users")
        XCTAssertTrue(sql.contains("OBJECT_ID(N'[dbo].[Users]')"))
        XCTAssertTrue(sql.contains("sys.indexes"))
    }

    func testForeignKeysQueryFiltersByTableAndSchema() {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: "dbo", table: "Orders")
        XCTAssertTrue(sql.contains("sys.foreign_keys"))
        XCTAssertTrue(sql.contains("N'Orders'"))
        XCTAssertTrue(sql.contains("N'dbo'"))
    }

    func testForeignKeysQuerySelectsReferencedSchema() {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: "dbo", table: "Orders")
        XCTAssertTrue(sql.contains("sr.name AS ref_schema"))
        XCTAssertTrue(sql.contains("JOIN sys.schemas sr ON tr.schema_id = sr.schema_id"))
    }

    func testParseTableRowDetectsView() {
        let row: [String?] = ["v_active_users", "VIEW"]
        XCTAssertEqual(MSSQLSchemaQueries.parseTableRow(row), MSSQLTableRow(name: "v_active_users", isView: true))
    }

    func testParseTableRowDefaultsToTable() {
        let row: [String?] = ["users", "BASE TABLE"]
        XCTAssertEqual(MSSQLSchemaQueries.parseTableRow(row), MSSQLTableRow(name: "users", isView: false))
    }

    func testParseTableRowRejectsMissingName() {
        XCTAssertNil(MSSQLSchemaQueries.parseTableRow([nil, "BASE TABLE"]))
    }

    func testParseColumnRowExtractsAllFields() {
        let row: [String?] = ["id", "int", nil, "10", "0", "NO", nil, "1", "1"]
        let parsed = MSSQLSchemaQueries.parseColumnRow(row)
        XCTAssertEqual(parsed?.name, "id")
        XCTAssertEqual(parsed?.dataType, "int")
        XCTAssertEqual(parsed?.isNullable, false)
        XCTAssertEqual(parsed?.isIdentity, true)
        XCTAssertEqual(parsed?.isPrimaryKey, true)
    }

    func testColumnDisplayTypeForFixedSizeOmitsLength() {
        let row: [String?] = ["id", "int", "4", nil, nil, "NO", nil, "0", "0"]
        XCTAssertEqual(MSSQLSchemaQueries.parseColumnRow(row)?.displayType, "int")
    }

    func testColumnDisplayTypeForVarcharIncludesLength() {
        let row: [String?] = ["name", "nvarchar", "100", nil, nil, "YES", nil, "0", "0"]
        XCTAssertEqual(MSSQLSchemaQueries.parseColumnRow(row)?.displayType, "nvarchar(100)")
    }

    func testColumnDisplayTypeForMaxLengthRendersMax() {
        let row: [String?] = ["body", "varchar", "-1", nil, nil, "YES", nil, "0", "0"]
        XCTAssertEqual(MSSQLSchemaQueries.parseColumnRow(row)?.displayType, "varchar(max)")
    }

    func testColumnDisplayTypeForDecimalIncludesPrecisionScale() {
        let row: [String?] = ["amount", "decimal", nil, "18", "2", "NO", nil, "0", "0"]
        XCTAssertEqual(MSSQLSchemaQueries.parseColumnRow(row)?.displayType, "decimal(18,2)")
    }

    func testParseIndexRowExtractsFlags() {
        let row: [String?] = ["IX_users_email", "1", "0", "email"]
        let parsed = MSSQLSchemaQueries.parseIndexRow(row)
        XCTAssertEqual(parsed?.name, "IX_users_email")
        XCTAssertEqual(parsed?.isUnique, true)
        XCTAssertEqual(parsed?.isPrimary, false)
        XCTAssertEqual(parsed?.columnName, "email")
    }

    func testParseIndexRowRejectsMissingColumn() {
        XCTAssertNil(MSSQLSchemaQueries.parseIndexRow(["IX_x", "0", "0", nil]))
    }

    func testParseForeignKeyRowExtractsAll() {
        let row: [String?] = ["FK_orders_users", "user_id", "users", "id", "sales"]
        let parsed = MSSQLSchemaQueries.parseForeignKeyRow(row)
        XCTAssertEqual(parsed?.constraintName, "FK_orders_users")
        XCTAssertEqual(parsed?.columnName, "user_id")
        XCTAssertEqual(parsed?.referencedTable, "users")
        XCTAssertEqual(parsed?.referencedColumn, "id")
        XCTAssertEqual(parsed?.referencedSchema, "sales")
    }

    func testParseForeignKeyRowWithoutReferencedSchema() {
        let row: [String?] = ["FK_orders_users", "user_id", "users", "id"]
        XCTAssertNil(MSSQLSchemaQueries.parseForeignKeyRow(row)?.referencedSchema)
    }

    func testQualifiedNamePrefixesSchema() {
        XCTAssertEqual(MSSQLSchemaQueries.qualifiedName(schema: "sales", table: "routeCache"), "[sales].[routeCache]")
    }

    func testQualifiedNameOmitsSchemaWhenNilOrEmpty() {
        XCTAssertEqual(MSSQLSchemaQueries.qualifiedName(schema: nil, table: "routeCache"), "[routeCache]")
        XCTAssertEqual(MSSQLSchemaQueries.qualifiedName(schema: "", table: "routeCache"), "[routeCache]")
    }

    func testBrowseQualifiesNonDefaultSchema() {
        let sql = MSSQLSchemaQueries.browse(
            schema: "sales", table: "routeCache",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        XCTAssertEqual(
            sql,
            "SELECT * FROM [sales].[routeCache] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY"
        )
    }

    func testBrowseWithoutSchemaStaysUnqualified() {
        let sql = MSSQLSchemaQueries.browse(
            schema: nil, table: "routeCache",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 10, limit: 50
        )
        XCTAssertEqual(
            sql,
            "SELECT * FROM [routeCache] ORDER BY (SELECT NULL) OFFSET 10 ROWS FETCH NEXT 50 ROWS ONLY"
        )
    }

    func testFilteredQualifiesSchemaAndAppendsWhere() {
        let sql = MSSQLSchemaQueries.filtered(
            schema: "sales", table: "routeCache", whereClause: "[id] = 1",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        XCTAssertEqual(
            sql,
            "SELECT * FROM [sales].[routeCache] WHERE [id] = 1 ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY"
        )
    }

    func testFilteredOmitsWhenWhereClauseEmpty() {
        let sql = MSSQLSchemaQueries.filtered(
            schema: "sales", table: "routeCache", whereClause: "",
            orderByClause: "ORDER BY (SELECT NULL)", offset: 0, limit: 200
        )
        XCTAssertEqual(
            sql,
            "SELECT * FROM [sales].[routeCache] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY"
        )
    }

    func testCatalogPredicatesSurviveANonAsciiName() {
        let columns = MSSQLSchemaQueries.columns(schema: "dbo", table: "顧客テーブル")
        XCTAssertTrue(columns.contains("N'顧客テーブル'"))
        XCTAssertFalse(columns.contains("= '顧客テーブル'"))

        let indexes = MSSQLSchemaQueries.indexes(schema: "dbo", table: "顧客テーブル")
        XCTAssertTrue(indexes.contains("OBJECT_ID(N'[dbo].[顧客テーブル]')"))

        let foreignKeys = MSSQLSchemaQueries.foreignKeys(schema: "スキーマ", table: "顧客テーブル")
        XCTAssertTrue(foreignKeys.contains("N'顧客テーブル'"))
        XCTAssertTrue(foreignKeys.contains("N'スキーマ'"))
    }

    func testFixedCatalogConstantsStayUnprefixed() {
        let tables = MSSQLSchemaQueries.tables(schema: "dbo")
        XCTAssertTrue(tables.contains("IN ('BASE TABLE', 'VIEW')"))
        XCTAssertTrue(MSSQLSchemaQueries.columns(schema: "dbo", table: "t").contains("= 'PRIMARY KEY'"))
        XCTAssertTrue(MSSQLSchemaQueries.schemas.contains("'information_schema'"))
    }
}
