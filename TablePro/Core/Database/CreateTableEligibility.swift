//
//  CreateTableEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Whether New Table can do anything on a connection. The Create Table editor turns a draft into
/// statements through the driver's form or its `generateCreateTableSQL`, and an engine with neither
/// used to be offered the editor anyway and refuse only after the grid was filled in. So the driver
/// is asked here, with a one-column probe, the way `DatabaseObjectToolEligibility` asks its hooks.
enum CreateTableEligibility {
    static let probeDefinition = PluginCreateTableDefinition(
        tableName: "t",
        columns: [
            PluginColumnDefinition(
                name: "c",
                dataType: "TEXT",
                isNullable: true,
                defaultValue: nil,
                isPrimaryKey: false,
                autoIncrement: false,
                comment: nil,
                unsigned: false,
                onUpdate: nil,
                charset: nil,
                collation: nil
            )
        ]
    )

    @MainActor
    static func canCreateTable(with driver: DatabaseDriver?) -> Bool {
        guard let driver else { return false }
        if driver.createTableFormSpec(schema: nil) != nil { return true }
        guard let adapter = driver as? PluginDriverAdapter else { return false }
        return adapter.generateCreateTableSQL(definition: probeDefinition) != nil
    }
}
