//
//  ClickHouseIndexEditTests.swift
//  TableProTests
//
//  What the ClickHouse driver writes when the structure editor adds, changes or creates a table with
//  an index: nothing, because an index row cannot say what a data skipping index is.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ClickHouse index edits")
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

    /// The issue used to say the database "does not create indexes with a statement", while the
    /// ClickHouse docs send the reader to `ALTER TABLE … ADD INDEX`, which is one.
    @Test("Create Table creates the table and says it cannot add the index")
    func createTableNamesTheIndexItCannotAdd() {
        let plan = CreateTablePlan(
            definition: PluginCreateTableDefinition(
                tableName: "events",
                columns: [PluginColumnDefinition(name: "user_id", dataType: "UInt64", isNullable: false)],
                primaryKeyColumns: []
            ),
            indexes: [PluginIndexDefinition(name: "ix_user", columns: ["user_id"], indexType: "BTREE")],
            issues: []
        )

        let composed = CreateTableStatementComposer.compose(plan: plan, driver: driver)

        #expect(composed.statements.count == 1)
        #expect(composed.issues.map(\.message) == ["Create Table cannot add an index on this database."])
        #expect(composed.issues.first?.tab == .indexes)
        #expect(composed.issues.first?.row == 0)
    }
}
