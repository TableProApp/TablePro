//
//  StarRocksCatalogTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct StarRocksCatalogTests {
    @Test("The Database field reads as a catalog and a database, a bare name, or nothing", arguments: [
        ("glue_iceberg_rest.lakehouse_events", StarRocksCatalog.ConfiguredTarget.qualified(
            catalog: "glue_iceberg_rest", database: "lakehouse_events"
        )),
        ("default_catalog.sales", .qualified(catalog: "default_catalog", database: "sales")),
        ("hive.", .qualified(catalog: "hive", database: "")),
        ("sales", .bareName("sales")),
        (".sales", .bareName("sales")),
        ("  sales  ", .bareName("sales")),
        ("", .serverDefault),
        ("   ", .serverDefault),
    ])
    func configuredTarget(text: String, expected: StarRocksCatalog.ConfiguredTarget) {
        #expect(StarRocksCatalog.target(fromConfiguredDatabase: text) == expected)
    }

    @Test("Only the first dot splits, so a database name keeps any dot after it")
    func firstDotSplits() {
        #expect(StarRocksCatalog.target(fromConfiguredDatabase: "iceberg.ns.events")
            == .qualified(catalog: "iceberg", database: "ns.events"))
    }

    @Test("Catalog and database switches quote the name")
    func statementsQuote() {
        #expect(StarRocksCatalog.setCatalog("glue_iceberg_rest") == "SET CATALOG `glue_iceberg_rest`")
        #expect(StarRocksCatalog.useDatabase("lake`events") == "USE `lake``events`")
    }

    @Test("Names come from the first column and skip empty cells")
    func namesFromRows() {
        let rows: [[PluginCellValue]] = [
            [.text("default_catalog"), .text("Internal")],
            [.text("glue_iceberg_rest"), .text("Iceberg")],
            [.text("")],
            [],
        ]
        #expect(StarRocksCatalog.names(from: rows) == ["default_catalog", "glue_iceberg_rest"])
    }

    @Test("StarRocks has no MySQL object catalogs and its databases are not system databases")
    func flavorShape() {
        let flavor = MySQLServerFlavor.starrocks
        #expect(flavor.isStarRocks)
        #expect(!flavor.hasMySQLObjectCatalogs)
        #expect(MySQLServerFlavor.databend.hasMySQLObjectCatalogs == false)
        #expect(MySQLServerFlavor.mysql.hasMySQLObjectCatalogs)
        #expect(flavor.systemDatabaseNames.isEmpty)
        #expect(!flavor.reportsSessionStatusFlags)
        #expect(!flavor.preparesOnServer)
        #expect(flavor.maintenanceOperations.isEmpty)
    }

    /// Iceberg VARIANT and JSON columns arrive as charset 63 with `BINARY_FLAG`, and read as hex without this.
    @Test("StarRocks binary-labelled strings decode as text when they are UTF-8")
    func binaryLabelledStringsAreText() {
        #expect(MySQLServerFlavor.starrocks.labelsTextResultsAsBinary)
        #expect(!MySQLServerFlavor.mysql.labelsTextResultsAsBinary)
        let varString: UInt32 = 253
        let decoding = MySQLColumnDecoding(
            typeRaw: varString, charsetnr: 63, characterSetName: "binary", flavor: .starrocks,
            binaryStringsAreText: MySQLServerFlavor.starrocks.labelsTextResultsAsBinary
        )
        #expect(decoding == .utf8TextOrBytes)
    }

    @Test("StarRocks begins with BEGIN whatever the access mode")
    func begins() {
        #expect(MySQLServerFlavor.starrocks.beginTransactionStatement(mode: .readWrite) == "BEGIN")
        #expect(MySQLServerFlavor.starrocks.beginTransactionStatement(mode: .serverDefault) == "BEGIN")
    }

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
        let config = DriverConnectionConfig(
            host: "localhost", port: 9_030, username: "root", password: "", database: "",
            additionalFields: ["driverVariant": MySQLServerFlavor.starrocksVariant]
        )
        #expect(MySQLPluginDriver.initialFlavor(for: config) == .starrocks)
    }

    @Test("A qualified Database field is held as the catalog and the database to enter")
    func driverHoldsQualifiedScope() {
        let driver = MySQLPluginDriver(config: Self.config(database: "glue_iceberg_rest.lakehouse_events"))
        #expect(driver.activeCatalogName == "glue_iceberg_rest")
        #expect(driver.activeDatabaseName == "lakehouse_events")
    }

    @Test("A bare name waits for the server to settle whether it is a catalog")
    func driverHoldsBareName() {
        let driver = MySQLPluginDriver(config: Self.config(database: "sales"))
        #expect(driver.activeCatalogName == nil)
        #expect(driver.activeDatabaseName == "sales")
    }

    @Test("A MySQL connection keeps a dotted name whole")
    func mysqlKeepsDottedName() {
        let driver = MySQLPluginDriver(config: DriverConnectionConfig(
            host: "localhost", port: 3_306, username: "root", password: "", database: "a.b"
        ))
        #expect(driver.activeCatalogName == nil)
        #expect(driver.activeDatabaseName == "a.b")
    }

    /// `information_schema.columns` rows as StarRocks 4.1.7 answers them, one table per key model.
    @Test("A primary, unique or aggregate key picks out a row, and a duplicate key does not")
    func keyModels() {
        let row: (String, String, String, String, String) -> [PluginCellValue] = { table, column, type, nullable, key in
            [.text(table), .text(column), .text(type), .text(nullable), .text(key), .null, .text("")]
        }
        let columns = StarRocksCatalog.columnsByTable(from: [
            row("pk", "id", "bigint(20)", "NO", "PRI"),
            row("pk", "v", "varchar(20)", "YES", ""),
            row("uq", "a", "int(11)", "YES", "UNI"),
            row("agg", "a", "int(11)", "YES", "AGG"),
            row("dup", "a", "int(11)", "YES", "DUP"),
        ])
        #expect(columns["pk"]?.map(\.isPrimaryKey) == [true, false])
        #expect(columns["pk"]?.first?.isNullable == false)
        #expect(columns["pk"]?.first?.dataType == "BIGINT(20)")
        #expect(columns["pk"]?.first?.comment == nil)
        #expect(columns["pk"]?.first?.defaultValue == nil)
        #expect(columns["uq"]?.first?.isPrimaryKey == true)
        #expect(columns["agg"]?.first?.isPrimaryKey == true)
        #expect(columns["dup"]?.first?.isPrimaryKey == false)
    }

    @Test("A column keeps its default and comment")
    func columnDetails() {
        let columns = StarRocksCatalog.columnsByTable(from: [
            [.text("cm"), .text("id"), .text("int(11)"), .text("NO"), .text("PRI"), .null, .text("the id")],
            [.text("cm"), .text("d"), .text("datetime"), .text("YES"), .text(""), .text("CURRENT_TIMESTAMP"), .text("")],
        ])
        #expect(columns["cm"]?.map(\.name) == ["id", "d"])
        #expect(columns["cm"]?.first?.comment == "the id")
        #expect(columns["cm"]?.last?.defaultValue == "CURRENT_TIMESTAMP")
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

    /// `SHOW TABLE STATUS` rows as StarRocks 4.1.7 answers them: MySQL's positions, a view at -1,
    /// and no index length.
    @Test("Table status reads the data length as the whole size, and a view's -1 as unknown")
    func tableStatus() {
        let table = Self.statusRow(name: "pk", engine: "StarRocks", rows: "42", avgRowLength: "12", dataLength: "504")
        let metadata = StarRocksCatalog.tableMetadata(fromStatusRow: table, tableName: "pk")
        #expect(metadata.rowCount == 42)
        #expect(metadata.dataSize == 504)
        #expect(metadata.totalSize == 504)
        #expect(metadata.indexSize == nil)
        #expect(metadata.engine == "StarRocks")
        #expect(metadata.collation == "utf8_general_ci")
        #expect(StarRocksCatalog.rowCount(fromStatusRow: table) == 42)

        let view = Self.statusRow(name: "v1", engine: nil, rows: "-1", avgRowLength: "-1", dataLength: "-1")
        let viewMetadata = StarRocksCatalog.tableMetadata(fromStatusRow: view, tableName: "v1")
        #expect(viewMetadata.rowCount == nil)
        #expect(viewMetadata.dataSize == nil)
        #expect(viewMetadata.engine == nil)
        #expect(StarRocksCatalog.rowCount(fromStatusRow: view) == nil)
    }

    private static func statusRow(
        name: String, engine: String?, rows: String, avgRowLength: String, dataLength: String
    ) -> [PluginCellValue] {
        [
            .text(name), engine.map { .text($0) } ?? .null, .null, .text(""), .text(rows), .text(avgRowLength),
            .text(dataLength), .null, .null, .null, .null, .text("2026-10-31 15:19:44"), .text("2026-10-31 15:19:44"),
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
