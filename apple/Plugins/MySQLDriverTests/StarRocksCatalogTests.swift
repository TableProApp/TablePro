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

    private static func config(database: String) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: "localhost", port: 9_030, username: "root", password: "", database: database,
            additionalFields: ["driverVariant": MySQLServerFlavor.starrocksVariant]
        )
    }
}
