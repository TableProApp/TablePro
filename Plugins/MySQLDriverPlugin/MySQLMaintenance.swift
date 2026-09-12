//
//  MySQLMaintenance.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// MySQL's maintenance operations and the statements they produce.
///
/// Pure, so the confirmation sheet's preview and the statement that runs are one function rather
/// than two implementations that drifted: the sheet printed `CHECK TABLE orders MEDIUM` with the
/// name unquoted where `CHECK TABLE \`orders\` MEDIUM` ran.
///
/// The kind sets come from the MySQL reference rather than from a probe, because no MySQL server was
/// available: `OPTIMIZE TABLE`, `ANALYZE TABLE` and `REPAIR TABLE` are documented on base tables and
/// partitioned tables, while `CHECK TABLE` is documented to check views as well, for references in
/// the view body to tables that no longer exist.
nonisolated internal enum MySQLMaintenance {
    internal static let optimize = "OPTIMIZE TABLE"
    internal static let analyze = "ANALYZE TABLE"
    internal static let check = "CHECK TABLE"
    internal static let repair = "REPAIR TABLE"

    internal static let modeKey = "mode"
    internal static let checkModes = ["QUICK", "FAST", "MEDIUM", "EXTENDED", "CHANGED"]
    internal static let defaultCheckMode = "MEDIUM"

    internal static let analyzeOperation = PluginMaintenanceOperation(
        name: analyze,
        appliesTo: [.table, .partitionedTable],
        scope: .object
    )

    internal static let operations: [PluginMaintenanceOperation] = [
        PluginMaintenanceOperation(
            name: optimize,
            appliesTo: [.table, .partitionedTable],
            scope: .object
        ),
        analyzeOperation,
        PluginMaintenanceOperation(
            name: check,
            appliesTo: [.table, .partitionedTable, .view],
            scope: .object,
            options: [
                PluginMaintenanceOption(
                    key: modeKey,
                    label: String(localized: "Check mode:"),
                    defaultValue: defaultCheckMode,
                    choices: checkModes
                )
            ]
        ),
        PluginMaintenanceOperation(
            name: repair,
            appliesTo: [.table, .partitionedTable],
            scope: .object
        )
    ]

    /// Every MySQL maintenance statement names one table, so a nil one produces nothing rather than a
    /// database-wide form the engine does not have.
    ///
    /// The mode is matched against the declared choices instead of being interpolated as it arrives.
    /// It reaches here from an MCP client as well as from the sheet's picker, and it lands in the
    /// statement text unquoted.
    internal static func statements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String],
        flavor: MySQLServerFlavor
    ) -> [String]? {
        guard let table, flavor.maintenanceOperations.contains(where: { $0.name == operation }) else { return nil }
        let target = qualified(table: table, schema: schema, flavor: flavor)
        switch operation {
        case optimize, analyze, repair:
            return ["\(operation) \(target)"]
        case check:
            let mode = checkModes.first { $0 == options[modeKey] } ?? defaultCheckMode
            return ["\(check) \(target) \(mode)"]
        default:
            return nil
        }
    }

    private static func qualified(table: String, schema: String?, flavor: MySQLServerFlavor) -> String {
        func quote(_ name: String) -> String {
            flavor.isDatabend ? DatabendCatalog.quoteIdentifier(name) : mysqlQuoteIdentifier(name)
        }
        guard let schema, !schema.isEmpty else { return quote(table) }
        return "\(quote(schema)).\(quote(table))"
    }
}

/// Which operations a flavor offers, kept beside the operations themselves rather than on the flavor.
///
/// `MySQLServerFlavor` is compiled into the iOS app as well as into this plugin, for the server
/// identity it carries, and the app runs no maintenance at all. Naming `MySQLMaintenance` from there
/// made the flavor unbuildable without this file and the two identifier-quoting files behind it.
internal extension MySQLServerFlavor {
    var maintenanceOperations: [PluginMaintenanceOperation] {
        switch self {
        case .mysql, .mariadb:
            return MySQLMaintenance.operations
        case .tidb, .databend:
            return [MySQLMaintenance.analyzeOperation]
        }
    }
}
