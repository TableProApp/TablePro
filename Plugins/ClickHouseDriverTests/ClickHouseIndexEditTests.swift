//
//  ClickHouseIndexEditTests.swift
//  ClickHouseDriverTests
//
//  What the ClickHouse driver writes when the structure editor adds an index: nothing, because an
//  index row cannot say what a data skipping index is.
//

import Foundation
import TableProPluginKit
import Testing

struct ClickHouseIndexEditTests {
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

    /// `DATA_SKIPPING` is what this driver reports for every such index and `BTREE` is what a new row
    /// holds. A row carries no expression, type arguments or granularity, so even a named type would
    /// have been written with a granularity the index never had.
    @Test("No index type gets a statement")
    func everyIndexIsDeclined() {
        for type in [nil, "DATA_SKIPPING", "BTREE", "minmax", "BLOOM_FILTER(0.01)"] {
            let index = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: type)
            #expect(driver.generateAddIndexSQL(table: "events", index: index) == nil, "\(type ?? "nil")")
        }
    }
}
