//
//  ClickHouseSkippingIndexTypeTests.swift
//  TableProTests
//
//  What the ClickHouse driver writes after TYPE when the structure editor adds or changes an index.
//  The type names and argument counts are the ones ClickHouse documents, not measured on a server.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ClickHouse data skipping index type")
struct ClickHouseSkippingIndexTypeTests {
    private var driver: ClickHousePluginDriver {
        ClickHousePluginDriver(config: DriverConnectionConfig(
            host: "localhost",
            port: 8_123,
            username: "default",
            password: "",
            database: "default",
            ssl: SSLConfiguration(),
            additionalFields: [:]
        ))
    }

    @Test("A documented type is written in its lowercase spelling, with numeric arguments kept")
    func documentedTypesAreWritten() {
        #expect(ClickHouseSkippingIndexType.clause(for: "MINMAX") == "minmax")
        #expect(ClickHouseSkippingIndexType.clause(for: "SET(100)") == "set(100)")
        #expect(ClickHouseSkippingIndexType.clause(for: "bloom_filter") == "bloom_filter")
        #expect(ClickHouseSkippingIndexType.clause(for: "BLOOM_FILTER(0.01)") == "bloom_filter(0.01)")
        #expect(ClickHouseSkippingIndexType.clause(for: "tokenbf_v1(32768,3, 0)") == "tokenbf_v1(32768, 3, 0)")
    }

    @Test("No type is the driver's own default")
    func missingTypeIsMinmax() {
        #expect(ClickHouseSkippingIndexType.clause(for: nil) == "minmax")
    }

    /// `DATA_SKIPPING` is what this driver reports for every such index, and `BTREE` is what a new row
    /// in the structure editor holds. Neither is a type the server has.
    @Test("A type ClickHouse has no data skipping index for is declined")
    func otherTypesAreDeclined() {
        for type in ["DATA_SKIPPING", "BTREE", "GIN", "SET", "minmax(1)", "ngrambf_v1(3, 256)", "bloom_filter()"] {
            #expect(ClickHouseSkippingIndexType.clause(for: type) == nil, "\(type)")
        }
    }

    @Test("Arguments that are not decimal numbers are declined, so nothing but a number reaches TYPE")
    func nonNumericArgumentsAreDeclined() {
        for type in ["set(nan)", "set(1) GRANULARITY 1", "set(1); DROP TABLE t", "bloom_filter('x')", "set(1e5)"] {
            #expect(ClickHouseSkippingIndexType.clause(for: type) == nil, "\(type)")
        }
    }

    /// A changed index is a drop and an add, and the app builds both before it runs either, so an add
    /// the driver declines keeps the index the table has.
    @Test("The driver writes no statement for a type it declines")
    func driverDeclinesUnknownTypes() {
        let skipping = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "DATA_SKIPPING")
        #expect(driver.generateAddIndexSQL(table: "events", index: skipping) == nil)

        let bloom = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "BLOOM_FILTER")
        #expect(driver.generateAddIndexSQL(table: "events", index: bloom)
            == "ALTER TABLE `events` ADD INDEX `ix` (`a`) TYPE bloom_filter GRANULARITY 1")
    }

    /// Before, the rename ran `DROP INDEX` and then an `ADD INDEX … TYPE BTREE` the server refuses, and
    /// ClickHouse has no transaction to undo the drop.
    @Test("Renaming a data-skipping index on the Indexes tab stops before its DROP INDEX is built")
    func renameStopsBeforeTheDrop() {
        let read = EditableIndexDefinition.from(IndexInfo(
            name: "ix_user", columns: ["user_id"], isUnique: false, isPrimary: false, type: "DATA_SKIPPING"
        ))
        var renamed = read
        renamed.name = "ix_user_id"
        let generator = SchemaStatementGenerator(tableName: "events", pluginDriver: driver)

        #expect(throws: (any Error).self) {
            try generator.generate(changes: [.modifyIndex(old: read, new: renamed)])
        }
    }
}
