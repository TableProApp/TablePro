//
//  ClickHouseDatabaseMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// `system.tables` has no row for a database that holds no tables, so a database list built from it dropped every
/// empty database, and the database switcher lost them the moment its metadata pass replaced the first list. The
/// rows here are what ClickHouse 24.8 returned for `SHOW DATABASES` and the per-database aggregate.
@Suite("ClickHouse database metadata")
struct ClickHouseDatabaseMetadataTests {
    private let names = ["INFORMATION_SCHEMA", "default", "empty_db", "information_schema", "populated_db", "system"]

    private let aggregateRows: [[PluginCellValue]] = [
        [.text("system"), .text("112"), .text("1268905")],
        [.text("populated_db"), .text("2"), .text("4221")],
        [.text("INFORMATION_SCHEMA"), .text("14"), .null],
        [.text("information_schema"), .text("14"), .null]
    ]

    @Test("Every database SHOW DATABASES returns is listed in its order, including ones with no tables")
    func everyListedDatabaseIsKept() {
        let metadata = ClickHousePluginDriver.databaseMetadata(names: names, aggregateRows: aggregateRows)

        #expect(metadata.map(\.name) == names)
    }

    @Test("A database with no tables reports zero tables and no size")
    func emptyDatabaseReportsZeroTables() {
        let metadata = ClickHousePluginDriver.databaseMetadata(names: names, aggregateRows: aggregateRows)
        let empty = metadata.first { $0.name == "empty_db" }

        #expect(empty?.tableCount == 0)
        #expect(empty?.sizeBytes == nil)
    }

    @Test("A database with tables takes its count and size from the aggregate")
    func populatedDatabaseTakesItsAggregate() {
        let metadata = ClickHousePluginDriver.databaseMetadata(names: names, aggregateRows: aggregateRows)
        let populated = metadata.first { $0.name == "populated_db" }
        let informationSchema = metadata.first { $0.name == "INFORMATION_SCHEMA" }

        #expect(populated?.tableCount == 2)
        #expect(populated?.sizeBytes == 4_221)
        #expect(informationSchema?.tableCount == 14)
        #expect(informationSchema?.sizeBytes == nil)
    }

    @Test("A database only the aggregate names is left out, because SHOW DATABASES is the list")
    func aggregateOnlyDatabaseIsLeftOut() {
        let metadata = ClickHousePluginDriver.databaseMetadata(
            names: ["default"],
            aggregateRows: [[.text("dropped_db"), .text("3"), .text("10")]]
        )

        #expect(metadata.map(\.name) == ["default"])
    }

    @Test("The aggregate reads system.tables once, grouped by database")
    func aggregateQueryGroupsSystemTables() {
        let query = ClickHousePluginDriver.databaseTableAggregateQuery

        #expect(query.contains("FROM system.tables"))
        #expect(query.contains("GROUP BY database"))
    }
}
