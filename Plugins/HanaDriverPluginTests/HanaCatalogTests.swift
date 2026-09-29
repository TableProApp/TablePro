import Foundation
import TableProPluginKit
import XCTest

final class HanaCatalogTests: XCTestCase {
    func testQuotingDoublesEveryQuoteEvenBeforeACombiningMark() {
        XCTAssertEqual(HanaSQL.quoteIdentifier("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(HanaSQL.quoteLiteral("a'b"), "N'a''b'")
        XCTAssertEqual(HanaSQL.quoteIdentifier("x\"\u{0301}y"), "\"x\"\"\u{0301}y\"")
        XCTAssertEqual(HanaSQL.quoteLiteral("x'\u{0301} OR 1=1 --"), "N'x''\u{0301} OR 1=1 --'")
        XCTAssertEqual(HanaSQL.escapeLiteralBody("a\0'b"), "a''b")
        XCTAssertEqual(HanaSQL.qualifiedName(schema: "S\"1", name: "T"), "\"S\"\"1\".\"T\"")
    }

    func testCatalogQueriesEscapeEveryLiteral() {
        let schema = "O'Brien\u{0301}"
        let table = "T'1"
        let queries = [
            HanaCatalogQueries.tables(schema: schema),
            HanaCatalogQueries.columns(schema: schema, table: table),
            HanaCatalogQueries.indexes(schema: schema, table: table),
            HanaCatalogQueries.foreignKeys(schema: schema, table: table),
            HanaCatalogQueries.tableMetadata(schema: schema, table: table),
            HanaCatalogQueries.viewComment(schema: schema, view: table),
            HanaCatalogQueries.approximateRowCount(schema: schema, table: table),
            HanaCatalogQueries.tableStore(schema: schema, table: table),
            HanaCatalogQueries.viewDefinition(schema: schema, view: table)
        ]
        for query in queries {
            XCTAssertTrue(query.contains("N'O''Brien\u{0301}'"), query)
            XCTAssertFalse(query.contains("N'O'Brien"), query)
        }
        XCTAssertTrue(HanaCatalogQueries.tableCount(schema: schema).contains("N'O''Brien\u{0301}'"))
        XCTAssertEqual(HanaCatalogQueries.setSchema("My \"Schema\""), "SET SCHEMA \"My \"\"Schema\"\"\"")
    }

    func testTablesQueryListsTablesAndViewsWithoutTableTypes() {
        let query = HanaCatalogQueries.tables(schema: "APP")
        XCTAssertTrue(query.contains("FROM SYS.TABLES"))
        XCTAssertTrue(query.contains("IS_USER_DEFINED_TYPE = 'FALSE'"))
        XCTAssertTrue(query.contains("FROM SYS.VIEWS"))
        XCTAssertTrue(query.contains("COMMENTS"))
    }

    func testColumnsQueryCoversTablesAndViewsAndFiltersOnlyWhenATableIsNamed() {
        let single = HanaCatalogQueries.columns(schema: "APP", table: "ORDERS")
        XCTAssertTrue(single.contains("FROM SYS.TABLE_COLUMNS"))
        XCTAssertTrue(single.contains("FROM SYS.VIEW_COLUMNS"))
        XCTAssertTrue(single.contains("AND TABLE_NAME = N'ORDERS'"))
        XCTAssertTrue(single.contains("AND VIEW_NAME = N'ORDERS'"))
        XCTAssertTrue(single.contains("K.IS_PRIMARY_KEY = 'TRUE'"))

        let bulk = HanaCatalogQueries.columns(schema: "APP", table: nil)
        XCTAssertFalse(bulk.contains("AND TABLE_NAME ="))
        XCTAssertFalse(bulk.contains("AND VIEW_NAME ="))
        XCTAssertTrue(bulk.contains("ORDER BY C.TABLE_NAME, C.POSITION"))
    }

    func testTypeRenderingAddsLengthPrecisionAndScaleWhereHanaDeclaresThem() {
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "NVARCHAR", length: 100, scale: nil), "NVARCHAR(100)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "VARCHAR", length: 20, scale: nil), "VARCHAR(20)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "CHAR", length: 1, scale: nil), "CHAR(1)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "NCHAR", length: 3, scale: nil), "NCHAR(3)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "ALPHANUM", length: 10, scale: nil), "ALPHANUM(10)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "SHORTTEXT", length: 50, scale: nil), "SHORTTEXT(50)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "VARBINARY", length: 16, scale: nil), "VARBINARY(16)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "BINARY", length: 8, scale: nil), "BINARY(8)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "DECIMAL", length: 10, scale: 2), "DECIMAL(10,2)")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "DECIMAL", length: 34, scale: nil), "DECIMAL")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "INTEGER", length: 10, scale: 0), "INTEGER")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "NCLOB", length: 2_147_483_647, scale: nil), "NCLOB")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "TIMESTAMP", length: 27, scale: 7), "TIMESTAMP")
        XCTAssertEqual(HanaCatalogMapping.renderedType(name: "NVARCHAR", length: nil, scale: nil), "NVARCHAR")
    }

    func testClassificationHintsCoverTypesTheAppDoesNotKnow() {
        XCTAssertEqual(HanaCatalogMapping.classificationTypeName(forTypeName: "SECONDDATE"), "TIMESTAMP")
        XCTAssertEqual(HanaCatalogMapping.classificationTypeName(forTypeName: "SMALLDECIMAL"), "DECIMAL")
        XCTAssertEqual(HanaCatalogMapping.classificationTypeName(forTypeName: "ST_POINT"), "TEXT")
        XCTAssertEqual(HanaCatalogMapping.classificationTypeName(forTypeName: "ST_GEOMETRY"), "TEXT")
        XCTAssertNil(HanaCatalogMapping.classificationTypeName(forTypeName: "NVARCHAR"))
        XCTAssertNil(HanaCatalogMapping.classificationTypeName(forTypeName: "TIMESTAMP"))
    }

    func testColumnRowsMapToPluginColumns() throws {
        let rows: [[PluginCellValue]] = [
            columnRow("ORDERS", "ID", "INTEGER", length: "10", scale: "0", nullable: "FALSE",
                      generation: "BY DEFAULT AS IDENTITY", keyPosition: "1"),
            columnRow("ORDERS", "NAME", "NVARCHAR", length: "100", nullable: "TRUE", defaultValue: "'guest'",
                      comment: "Display name"),
            columnRow("ORDERS", "TOTAL", "DECIMAL", length: "12", scale: "2", nullable: "TRUE",
                      generation: "ALWAYS AS", expression: "\"PRICE\" * \"QTY\""),
            columnRow("ORDERS", "CREATED", "SECONDDATE", length: "19", nullable: "TRUE")
        ]
        let columns = HanaCatalogMapping.columns(from: rows).map(\.pluginColumn)

        XCTAssertEqual(columns.map(\.name), ["ID", "NAME", "TOTAL", "CREATED"])
        XCTAssertEqual(columns.map(\.dataType), ["INTEGER", "NVARCHAR(100)", "DECIMAL(12,2)", "SECONDDATE"])

        XCTAssertTrue(columns[0].isPrimaryKey)
        XCTAssertFalse(columns[0].isNullable)
        XCTAssertEqual(columns[0].identityKind, .byDefault)
        XCTAssertFalse(columns[0].isGenerated)

        XCTAssertFalse(columns[1].isPrimaryKey)
        XCTAssertTrue(columns[1].isNullable)
        XCTAssertEqual(columns[1].defaultValue, "'guest'")
        XCTAssertEqual(columns[1].comment, "Display name")
        XCTAssertNil(columns[1].identityKind)

        XCTAssertTrue(columns[2].isGenerated)
        XCTAssertEqual(columns[2].generationKind, .stored)
        XCTAssertEqual(columns[2].generationExpression, "\"PRICE\" * \"QTY\"")

        XCTAssertEqual(columns[3].classificationTypeName, "TIMESTAMP")
        XCTAssertNil(columns[0].classificationTypeName)
    }

    func testGenerationTypesMapToIdentityAndComputedKinds() {
        XCTAssertEqual(HanaColumnGeneration(generationType: "ALWAYS AS IDENTITY"), .identity(.always))
        XCTAssertEqual(HanaColumnGeneration(generationType: "BY DEFAULT AS IDENTITY"), .identity(.byDefault))
        XCTAssertEqual(HanaColumnGeneration(generationType: "always  as"), .computed(.stored))
        XCTAssertEqual(HanaColumnGeneration(generationType: "ALWAYS CALCULATED AS"), .computed(.virtual))
        XCTAssertEqual(HanaColumnGeneration(generationType: "ALWAYS AS ROW START"), .systemTime)
        XCTAssertEqual(HanaColumnGeneration(generationType: "ALWAYS AS ROW END"), .systemTime)
        XCTAssertNil(HanaColumnGeneration(generationType: nil))
        XCTAssertNil(HanaColumnGeneration(generationType: "SOMETHING ELSE"))

        let systemTime = HanaCatalogColumn(table: "T", name: "VALID_FROM", typeName: "TIMESTAMP", generation: .systemTime)
        XCTAssertTrue(systemTime.pluginColumn.isGenerated)
        XCTAssertNil(systemTime.pluginColumn.identityKind)
    }

    func testBulkColumnsGroupByTable() {
        let rows: [[PluginCellValue]] = [
            columnRow("A", "ID", "INTEGER"),
            columnRow("A", "NAME", "NVARCHAR", length: "10"),
            columnRow("B_VIEW", "ID", "INTEGER")
        ]
        let grouped = HanaCatalogMapping.columnsByTable(from: rows)

        XCTAssertEqual(grouped["A"]?.map(\.name), ["ID", "NAME"])
        XCTAssertEqual(grouped["B_VIEW"]?.map(\.name), ["ID"])
    }

    func testTablesMapTypeSchemaAndComment() {
        let rows: [[PluginCellValue]] = [
            [.text("ORDERS"), .text("TABLE"), .text("Customer orders")],
            [.text("V_ORDERS"), .text("VIEW"), .null]
        ]
        let tables = HanaCatalogMapping.tables(from: rows, schema: "APP")

        XCTAssertEqual(tables.map(\.name), ["ORDERS", "V_ORDERS"])
        XCTAssertEqual(tables.map(\.type), ["TABLE", "VIEW"])
        XCTAssertEqual(tables.map(\.schema), ["APP", "APP"])
        XCTAssertEqual(tables.map(\.comment), ["Customer orders", nil])
    }

    func testIndexRowsGroupInKeyOrderWithConstraintKinds() {
        let rows: [[PluginCellValue]] = [
            [.text("IDX_NAME"), .text("CPBTREE"), .null, .text("LAST")],
            [.text("IDX_NAME"), .text("CPBTREE"), .null, .text("FIRST")],
            [.text("SYS_TREE_CS_#1_#0_#PK"), .text("INVERTED VALUE"), .text("PRIMARY_KEY"), .text("ID")],
            [.text("UQ_EMAIL"), .text("INVERTED VALUE"), .text("NOT_NULL_UNIQUE"), .text("EMAIL")],
            [.text("UQ_CODE"), .text("BTREE"), .text("UNIQUE"), .text("CODE")],
            [.text("FT_BODY"), .text("FULLTEXT"), .text("FULLTEXT"), .text("BODY")]
        ]
        let indexes = HanaCatalogMapping.indexes(from: rows)

        XCTAssertEqual(indexes.map(\.name), ["IDX_NAME", "SYS_TREE_CS_#1_#0_#PK", "UQ_EMAIL", "UQ_CODE", "FT_BODY"])
        XCTAssertEqual(indexes[0].columns, ["LAST", "FIRST"])
        XCTAssertEqual(indexes[0].type, "CPBTREE")
        XCTAssertFalse(indexes[0].isUnique)
        XCTAssertFalse(indexes[0].isPrimary)
        XCTAssertTrue(indexes[1].isPrimary)
        XCTAssertTrue(indexes[1].isUnique)
        XCTAssertTrue(indexes[2].isUnique)
        XCTAssertFalse(indexes[2].isPrimary)
        XCTAssertTrue(indexes[3].isUnique)
        XCTAssertFalse(indexes[4].isUnique)
        XCTAssertEqual(indexes[4].type, "FULLTEXT")
    }

    func testSpacedConstraintSpellingsAreRecognised() {
        let rows: [[PluginCellValue]] = [[.text("PK"), .text("BTREE"), .text("PRIMARY KEY"), .text("ID")]]
        let index = HanaCatalogMapping.indexes(from: rows)[0]
        XCTAssertTrue(index.isPrimary)
        XCTAssertTrue(index.isUnique)
    }

    func testForeignKeyRowsKeepConstraintColumnOrderAndRules() {
        let rows: [[PluginCellValue]] = [
            [.text("FK_LINE_ORDER"), .text("ORDER_ID"), .text("SALES"), .text("ORDERS"), .text("ID"),
             .text("CASCADE"), .text("SET NULL")],
            [.text("FK_LINE_ORDER"), .text("ORDER_REGION"), .text("SALES"), .text("ORDERS"), .text("REGION"),
             .text("CASCADE"), .text("SET NULL")],
            [.text("FK_LINE_ITEM"), .text("ITEM_ID"), .null, .text("ITEMS"), .text("ID"), .null, .null]
        ]
        let keys = HanaCatalogMapping.foreignKeys(from: rows)

        XCTAssertEqual(keys.map(\.name), ["FK_LINE_ORDER", "FK_LINE_ORDER", "FK_LINE_ITEM"])
        XCTAssertEqual(keys.map(\.column), ["ORDER_ID", "ORDER_REGION", "ITEM_ID"])
        XCTAssertEqual(keys.map(\.referencedColumn), ["ID", "REGION", "ID"])
        XCTAssertEqual(keys[0].referencedTable, "ORDERS")
        XCTAssertEqual(keys[0].referencedSchema, "SALES")
        XCTAssertEqual(keys[0].onUpdate, "CASCADE")
        XCTAssertEqual(keys[0].onDelete, "SET NULL")
        XCTAssertNil(keys[2].referencedSchema)
        XCTAssertEqual(keys[2].onDelete, "RESTRICT")
        XCTAssertEqual(keys[2].onUpdate, "RESTRICT")
    }

    func testTableMetadataReadsCountSizeCommentAndStore() {
        let metadata = HanaCatalogMapping.tableMetadata(
            table: "ORDERS",
            row: [.text("COLUMN"), .text("Orders"), .text("1250"), .text("65536")]
        )

        XCTAssertEqual(metadata.tableName, "ORDERS")
        XCTAssertEqual(metadata.rowCount, 1_250)
        XCTAssertEqual(metadata.dataSize, 65_536)
        XCTAssertEqual(metadata.totalSize, 65_536)
        XCTAssertEqual(metadata.comment, "Orders")
        XCTAssertEqual(metadata.engine, "COLUMN")
    }

    func testTableDDLCarriesStoreTypesDefaultsIdentityAndPrimaryKeyInKeyOrder() {
        let columns = [
            HanaCatalogColumn(table: "T", name: "REGION", typeName: "NVARCHAR", length: 2, isNullable: false,
                              primaryKeyPosition: 2),
            HanaCatalogColumn(table: "T", name: "ID", typeName: "BIGINT", isNullable: false,
                              generation: .identity(.always), primaryKeyPosition: 1),
            HanaCatalogColumn(table: "T", name: "NOTE", typeName: "NVARCHAR", length: 50, defaultValue: "'n/a'"),
            HanaCatalogColumn(table: "T", name: "AMOUNT", typeName: "DECIMAL", length: 10, scale: 2),
            HanaCatalogColumn(table: "T", name: "TAX", typeName: "DECIMAL", length: 10, scale: 2,
                              generation: .computed(.stored), generationExpression: "\"AMOUNT\" * 0.2"),
            HanaCatalogColumn(table: "T", name: "LABEL", typeName: "NVARCHAR", length: 60,
                              generation: .computed(.virtual), generationExpression: "UPPER(\"NOTE\")"),
            HanaCatalogColumn(table: "T", name: "SEQ", typeName: "INTEGER", isNullable: false,
                              generation: .identity(.byDefault))
        ]
        let ddl = HanaCatalogMapping.tableDDL(schema: "APP", table: "T", isColumnTable: true, columns: columns)

        XCTAssertEqual(ddl, """
            CREATE COLUMN TABLE "APP"."T" (
                "REGION" NVARCHAR(2) NOT NULL,
                "ID" BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
                "NOTE" NVARCHAR(50) DEFAULT 'n/a',
                "AMOUNT" DECIMAL(10,2),
                "TAX" DECIMAL(10,2) GENERATED ALWAYS AS ("AMOUNT" * 0.2),
                "LABEL" NVARCHAR(60) AS (UPPER("NOTE")),
                "SEQ" INTEGER GENERATED BY DEFAULT AS IDENTITY NOT NULL,
                PRIMARY KEY ("ID", "REGION")
            );
            """)
    }

    func testRowTableDDLQuotesNamesAndOmitsAnAbsentPrimaryKey() {
        let columns = [HanaCatalogColumn(table: "odd\"name", name: "a\"b", typeName: "INTEGER")]
        let ddl = HanaCatalogMapping.tableDDL(schema: "s", table: "odd\"name", isColumnTable: false, columns: columns)

        XCTAssertEqual(ddl, "CREATE ROW TABLE \"s\".\"odd\"\"name\" (\n    \"a\"\"b\" INTEGER\n);")
    }

    func testViewDDLPrependsTheCreateHeader() {
        XCTAssertEqual(
            HanaCatalogMapping.viewDDL(schema: "APP", view: "V\"1", definition: "SELECT 1 FROM DUMMY"),
            "CREATE VIEW \"APP\".\"V\"\"1\" AS\nSELECT 1 FROM DUMMY"
        )
    }

    func testDefaultsAreQuotedForCharacterAndDateColumnsOnly() {
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("guest", typeName: "NVARCHAR"), "N'guest'")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("it's", typeName: "VARCHAR"), "N'it''s'")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("", typeName: "NVARCHAR"), "N''")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("2020-01-01", typeName: "DATE"), "N'2020-01-01'")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("'kept'", typeName: "NVARCHAR"), "'kept'")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("N'kept'", typeName: "NCHAR"), "N'kept'")
        XCTAssertEqual(
            HanaCatalogMapping.renderedDefault("CURRENT_TIMESTAMP", typeName: "TIMESTAMP"),
            "CURRENT_TIMESTAMP"
        )
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("current_date", typeName: "DATE"), "current_date")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("0", typeName: "INTEGER"), "0")
        XCTAssertEqual(HanaCatalogMapping.renderedDefault("TRUE", typeName: "BOOLEAN"), "TRUE")
    }

    func testTableDDLQuotesABareCharacterDefault() {
        let columns = [
            HanaCatalogColumn(table: "T", name: "NAME", typeName: "NVARCHAR", length: 20, defaultValue: "guest"),
            HanaCatalogColumn(table: "T", name: "QTY", typeName: "INTEGER", defaultValue: "1")
        ]
        let ddl = HanaCatalogMapping.tableDDL(schema: "APP", table: "T", isColumnTable: true, columns: columns)

        XCTAssertTrue(ddl.contains("\"NAME\" NVARCHAR(20) DEFAULT N'guest'"), ddl)
        XCTAssertTrue(ddl.contains("\"QTY\" INTEGER DEFAULT 1"), ddl)
    }

    func testIndexStatementsSkipThePrimaryKeyAndKeepUniquenessTypeAndOrder() {
        let rows: [[PluginCellValue]] = [
            [.text("PK_T"), .text("CPBTREE"), .text("PRIMARY KEY"), .text("ID"), .text("TRUE")],
            [.text("UQ_EMAIL"), .text("CPBTREE"), .text("UNIQUE"), .text("EMAIL"), .text("TRUE")],
            [.text("IX_NAME"), .text("BTREE"), .null, .text("LAST"), .text("TRUE")],
            [.text("IX_NAME"), .text("BTREE"), .null, .text("FIRST"), .text("FALSE")],
            [.text("IX_VALUE"), .text("inverted  value"), .null, .text("CODE"), .text("TRUE")],
            [.text("IX_GEO"), .text("GEOCODE"), .null, .text("ADDRESS"), .text("TRUE")]
        ]
        let statements = HanaCatalogMapping.indexStatements(schema: "APP", table: "T", rows: rows)

        XCTAssertEqual(statements, [
            #"CREATE UNIQUE CPBTREE INDEX "APP"."UQ_EMAIL" ON "APP"."T" ("EMAIL");"#,
            #"CREATE BTREE INDEX "APP"."IX_NAME" ON "APP"."T" ("LAST", "FIRST" DESC);"#,
            #"CREATE INVERTED VALUE INDEX "APP"."IX_VALUE" ON "APP"."T" ("CODE");"#
        ])
    }

    func testCommentStatementsCoverTheRelationAndItsColumns() {
        let columns = [
            HanaCatalogColumn(table: "V", name: "ID", typeName: "INTEGER"),
            HanaCatalogColumn(table: "V", name: "NOTE", typeName: "NVARCHAR", length: 10, comment: "free 'text'")
        ]
        let statements = HanaCatalogMapping.commentStatements(
            schema: "APP",
            table: "V",
            relation: [.text("VIEW"), .text("Active orders")],
            columns: columns
        )

        XCTAssertEqual(statements, [
            #"COMMENT ON VIEW "APP"."V" IS N'Active orders';"#,
            #"COMMENT ON COLUMN "APP"."V"."NOTE" IS N'free ''text''';"#
        ])
        XCTAssertEqual(
            HanaCatalogMapping.commentStatements(
                schema: "APP",
                table: "T",
                relation: [.text("TABLE"), .null],
                columns: []
            ),
            []
        )
    }

    private func columnRow(
        _ table: String,
        _ name: String,
        _ type: String,
        length: String? = nil,
        scale: String? = nil,
        nullable: String = "TRUE",
        defaultValue: String? = nil,
        comment: String? = nil,
        generation: String? = nil,
        expression: String? = nil,
        keyPosition: String? = nil
    ) -> [PluginCellValue] {
        [
            .text(table), .text(name), .text(type), .fromOptional(length), .fromOptional(scale), .text(nullable),
            .fromOptional(defaultValue), .fromOptional(comment), .fromOptional(generation), .fromOptional(expression),
            .fromOptional(keyPosition)
        ]
    }
}
