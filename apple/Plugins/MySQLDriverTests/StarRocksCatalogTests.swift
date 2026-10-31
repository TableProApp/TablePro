//
//  StarRocksCatalogTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct StarRocksCatalogTests {
    @Test("The Database field reads as catalog.database, and a bare name as a database in default_catalog", arguments: [
        ("glue_iceberg_rest.lakehouse_events", "glue_iceberg_rest", "lakehouse_events"),
        ("default_catalog.sales", "default_catalog", "sales"),
        ("hive.", "hive", ""),
        ("sales", "default_catalog", "sales"),
        (".sales", "default_catalog", "sales"),
        ("  sales  ", "default_catalog", "sales"),
        ("iceberg.ns.events", "iceberg", "ns.events"),
        ("", "default_catalog", ""),
        ("   ", "default_catalog", ""),
    ])
    func configuredScope(text: String, catalog: String, database: String) {
        #expect(StarRocksCatalog.Scope(configuredDatabase: text) == StarRocksCatalog.Scope(catalog: catalog, database: database))
    }

    // Measured on 4.1.7: USE `default_catalog.idb` enters both, USE `default_catalog`.`idb` fails with 5501.
    @Test("A scope is entered in one statement, with catalog.database quoted as one name")
    func enterStatements() {
        #expect(StarRocksCatalog.Scope(catalog: "hive", database: "").enterStatement == "SET CATALOG `hive`")
        #expect(StarRocksCatalog.Scope(catalog: "ice", database: "idb").enterStatement == "USE `ice.idb`")
        #expect(StarRocksCatalog.Scope(catalog: "ice", database: "lake`events").enterStatement == "USE `ice.lake``events`")
    }

    // Measured on 4.1.7: SET CATALOG clears the database even when the catalog does not change.
    @Test("Entering the same catalog keeps the database, and another catalog leaves none")
    func enteringCatalog() {
        let scope = StarRocksCatalog.Scope(catalog: "ice", database: "idb")
        #expect(scope.entering(catalog: "ice") == scope)
        #expect(scope.entering(catalog: "default_catalog") == StarRocksCatalog.Scope(catalog: "default_catalog", database: ""))
    }

    @Test("Only default_catalog keeps table status, and only an empty default_catalog scope needs no statement")
    func scopeQuestions() {
        #expect(StarRocksCatalog.Scope(catalog: "default_catalog", database: "idb").keepsTableStatus)
        #expect(!StarRocksCatalog.Scope(catalog: "ice", database: "idb").keepsTableStatus)
        #expect(StarRocksCatalog.Scope(configuredDatabase: "").isServerDefault)
        #expect(!StarRocksCatalog.Scope(configuredDatabase: "sales").isServerDefault)
        #expect(!StarRocksCatalog.Scope(configuredDatabase: "ice.").isServerDefault)
    }

    @Test("Names come from the first column and skip empty cells")
    func namesFromRows() {
        let rows: [[PluginCellValue]] = [
            [.text("default_catalog"), .text("Internal")],
            [.text("ice"), .text("Iceberg")],
            [.text("")],
            [],
        ]
        #expect(StarRocksCatalog.names(from: rows) == ["default_catalog", "ice"])
    }

    @Test("StarRocks has no MySQL object catalogs and its catalogs are not system databases")
    func flavorShape() {
        let flavor = MySQLServerFlavor.starrocks
        #expect(flavor.isStarRocks)
        #expect(!flavor.hasMySQLObjectCatalogs)
        #expect(!MySQLServerFlavor.databend.hasMySQLObjectCatalogs)
        #expect(MySQLServerFlavor.mysql.hasMySQLObjectCatalogs)
        #expect(flavor.systemDatabaseNames.isEmpty)
        #expect(!flavor.reportsSessionStatusFlags)
        #expect(!flavor.preparesOnServer)
        #expect(flavor.maintenanceOperations.isEmpty)
    }

    // Measured on 4.1.7: VARBINARY and CAST AS VARBINARY arrive as BLOB (252) with charset 63.
    @Test("A charset 63 string reads as text when it is UTF-8, and a BLOB stays bytes")
    func binaryLabelledStrings() {
        let textOrBytes = MySQLColumnDecoding(
            typeRaw: 253, charsetnr: 63, characterSetName: "binary", flavor: .starrocks,
            binaryStringsAreText: MySQLServerFlavor.starrocks.labelsTextResultsAsBinary
        )
        let blob = MySQLColumnDecoding(
            typeRaw: 252, charsetnr: 63, characterSetName: "binary", flavor: .starrocks,
            binaryStringsAreText: MySQLServerFlavor.starrocks.labelsTextResultsAsBinary
        )
        #expect(textOrBytes == .utf8TextOrBytes)
        #expect(blob == .bytes)
        #expect(!MySQLServerFlavor.mysql.labelsTextResultsAsBinary)
    }

    @Test("StarRocks begins with BEGIN whatever the access mode")
    func begins() {
        #expect(MySQLServerFlavor.starrocks.beginTransactionStatement(mode: .readWrite) == "BEGIN")
        #expect(MySQLServerFlavor.starrocks.beginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }

    // Measured on 4.1.7: `SET query_timeout = 259201` fails with "must be equal or smaller than 259200".
    @Test("The query timeout is capped at StarRocks's maximum, which also stands in for no limit", arguments: [
        (30, "SET query_timeout = 30"),
        (300_000, "SET query_timeout = 259200"),
        (0, "SET query_timeout = 259200"),
    ])
    func queryTimeout(seconds: Int, expected: String) {
        #expect(MySQLServerFlavor.starrocks.queryTimeoutStatements(seconds: seconds) == [expected])
    }

    @Test("The StarRocks connection type starts as StarRocks before the probe")
    func initialFlavor() {
        #expect(MySQLPluginDriver.initialFlavor(for: Self.config(database: "")) == .starrocks)
    }

    @Test("The driver reports the catalog as its database and the database inside it as its schema")
    func driverScope() {
        let qualified = MySQLPluginDriver(config: Self.config(database: "glue.lakehouse"))
        #expect(qualified.currentDatabase == "glue")
        #expect(qualified.currentSchema == "lakehouse")

        let bare = MySQLPluginDriver(config: Self.config(database: "sales"))
        #expect(bare.currentDatabase == "default_catalog")
        #expect(bare.currentSchema == "sales")

        let catalogOnly = MySQLPluginDriver(config: Self.config(database: "ice."))
        #expect(catalogOnly.currentDatabase == "ice")
        #expect(catalogOnly.currentSchema == nil)
    }

    @Test("A MySQL connection keeps a dotted name whole and reports no schema level")
    func mysqlKeepsDottedName() {
        let driver = MySQLPluginDriver(config: DriverConnectionConfig(
            host: "localhost", port: 3_306, username: "root", password: "", database: "a.b"
        ))
        #expect(driver.activeDatabaseName == "a.b")
        #expect(driver.currentDatabase == nil)
        #expect(driver.currentSchema == nil)
    }

    // `information_schema.columns` rows as 4.1.7 answers them, one table per key model.
    @Test("A primary, unique or aggregate key picks out a row, and a duplicate key does not")
    func keyModels() {
        let row: (String, String, String, String, String) -> [PluginCellValue] = { table, column, type, nullable, key in
            [.text(table), .text(column), .text(type), .text(nullable), .text(key), .null, .text("")]
        }
        let columns = StarRocksCatalog.columnsByTable(from: [
            row("pk", "id", "int(11)", "NO", "PRI"),
            row("pk", "s", "varchar(20)", "YES", ""),
            row("uniq", "id", "int(11)", "YES", "UNI"),
            row("agg", "id", "int(11)", "YES", "AGG"),
            row("dup", "id", "int(11)", "YES", "DUP"),
        ])
        #expect(columns["pk"]?.map(\.isPrimaryKey) == [true, false])
        #expect(columns["pk"]?.first?.isNullable == false)
        #expect(columns["pk"]?.first?.dataType == "INT(11)")
        #expect(columns["pk"]?.first?.comment == nil)
        #expect(columns["uniq"]?.first?.isPrimaryKey == true)
        #expect(columns["agg"]?.first?.isPrimaryKey == true)
        #expect(columns["dup"]?.first?.isPrimaryKey == false)
    }

    // 4.1.7 reports `VARCHAR DEFAULT "abc"` as abc, `BIGINT DEFAULT "0"` as 0, and no default as NULL.
    @Test("A column default reads as the SQL that follows DEFAULT")
    func columnDefaults() {
        let row: (String, String, String, PluginCellValue) -> [PluginCellValue] = { column, type, nullable, value in
            [.text("dup"), .text(column), .text(type), .text(nullable), .text(""), value, .text("")]
        }
        let columns = StarRocksCatalog.columnsByTable(from: [
            row("s", "varchar(20)", "YES", .text("abc")),
            row("c", "bigint(20)", "YES", .text("0")),
            row("ts", "datetime", "YES", .text("CURRENT_TIMESTAMP")),
            row("n", "int(11)", "YES", .null),
            row("k", "int(11)", "NO", .null),
            [.text("cm"), .text("id"), .text("int(11)"), .text("NO"), .text("PRI"), .null, .text("the id")],
        ])
        #expect(columns["dup"]?.map(\.defaultValue) == ["'abc'", "0", "CURRENT_TIMESTAMP", "NULL", nil])
        #expect(columns["cm"]?.first?.comment == "the id")
    }

    @Test("Catalog reads escape the names they filter on")
    func catalogReadsEscape() {
        #expect(StarRocksCatalog.columns(database: "o'b", table: "t'1").contains("TABLE_SCHEMA = 'o''b' AND TABLE_NAME = 't''1'"))
        #expect(!StarRocksCatalog.columns(database: "db", table: nil).contains("TABLE_NAME ="))
        #expect(StarRocksCatalog.materializedViewNames(database: "o'b").contains("TABLE_SCHEMA = 'o''b'"))
    }

    @Test("A materialized view listed as VIEW is retyped, and the rest keep their type")
    func materializedViews() {
        let tables = [
            PluginTableInfo(name: "dup", type: "TABLE", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil),
            PluginTableInfo(name: "mv1", type: "VIEW", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil),
            PluginTableInfo(name: "v1", type: "VIEW", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil),
        ]
        let marked = StarRocksCatalog.markingMaterializedViews(["mv1"], in: tables)
        #expect(marked.map(\.type) == ["TABLE", "MATERIALIZED VIEW", "VIEW"])
    }

    // `SHOW TABLE STATUS` rows as 4.1.7 answers them: a view at -1, and Index_length NULL.
    @Test("Table status reads the data length as the whole size, and a view's -1 as unknown")
    func tableStatus() {
        let table = Self.statusRow(name: "dup", engine: "StarRocks", rows: "2", dataLength: "2148")
        let metadata = MySQLTableStatusRow.metadata(from: table, tableName: "dup", reportsIndexLength: false)
        #expect(metadata.rowCount == 2)
        #expect(metadata.dataSize == 2_148)
        #expect(metadata.totalSize == 2_148)
        #expect(metadata.indexSize == nil)
        #expect(metadata.engine == "StarRocks")
        #expect(metadata.collation == "utf8_general_ci")

        let view = Self.statusRow(name: "v1", engine: nil, rows: "-1", dataLength: "-1")
        let viewMetadata = MySQLTableStatusRow.metadata(from: view, tableName: "v1", reportsIndexLength: false)
        #expect(viewMetadata.rowCount == nil)
        #expect(viewMetadata.dataSize == nil)
        #expect(viewMetadata.totalSize == nil)
        #expect(viewMetadata.engine == nil)
    }

    private static func statusRow(name: String, engine: String?, rows: String, dataLength: String) -> [PluginCellValue] {
        [
            .text(name), engine.map { .text($0) } ?? .null, .null, .text(""), .text(rows), .text(rows),
            .text(dataLength), .null, .null, .null, .null, .text("2026-10-31 19:56:50"), .text("2026-10-31 19:58:00"),
            .null, .text("utf8_general_ci"), .null, .text(""), .text(""),
        ]
    }

    private static func config(database: String) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: "localhost", port: 9_030, username: "root", password: "", database: database,
            additionalFields: ["driverVariant": MySQLServerFlavor.starrocksVariant]
        )
    }
}
