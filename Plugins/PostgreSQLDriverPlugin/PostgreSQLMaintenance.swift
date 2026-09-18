//
//  PostgreSQLMaintenance.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// PostgreSQL's maintenance operations and the statements they produce.
///
/// Pure, so the confirmation sheet's preview and the statement that runs are one function rather
/// than two implementations that drifted: the sheet used to print `REINDEX orders`, which is not
/// valid SQL, where `REINDEX TABLE "orders"` ran.
///
/// Every kind set below is what PostgreSQL 17.11 answered to the statement on that kind. The two
/// that are not obvious: `CLUSTER` is accepted on a partitioned table and can never succeed there,
/// because `ALTER TABLE … CLUSTER ON` refuses with "cannot mark index clustered in partitioned
/// table"; and `ANALYZE` on a foreign table succeeds with no warning and writes `pg_statistic` rows,
/// because the wrapper samples it, while `VACUUM` on the same table warns and skips.
internal enum PostgreSQLMaintenance {
    internal static let vacuum = "VACUUM"
    internal static let analyze = "ANALYZE"
    internal static let reindex = "REINDEX"
    internal static let cluster = "CLUSTER"

    internal static let verboseKey = "verbose"
    internal static let fullKey = "full"
    internal static let analyzeKey = "analyze"

    internal static let operations: [PluginMaintenanceOperation] = [
        PluginMaintenanceOperation(
            name: vacuum,
            appliesTo: [.table, .partitionedTable, .materializedView],
            scope: .objectOrDatabase,
            options: [
                PluginMaintenanceOption(
                    key: fullKey,
                    label: String(localized: "FULL (rewrites the whole object, blocks access)"),
                    defaultValue: "false"
                ),
                PluginMaintenanceOption(
                    key: analyzeKey,
                    label: String(localized: "ANALYZE (update statistics afterwards)"),
                    defaultValue: "false"
                ),
                PluginMaintenanceOption(
                    key: verboseKey,
                    label: String(localized: "VERBOSE (report progress)"),
                    defaultValue: "false"
                )
            ]
        ),
        PluginMaintenanceOperation(
            name: analyze,
            appliesTo: [.table, .partitionedTable, .materializedView, .foreignTable],
            scope: .objectOrDatabase
        ),
        PluginMaintenanceOperation(
            name: reindex,
            appliesTo: [.table, .partitionedTable, .materializedView],
            scope: .objectOrDatabase,
            options: [
                PluginMaintenanceOption(
                    key: verboseKey,
                    label: String(localized: "VERBOSE (report progress)"),
                    defaultValue: "false"
                )
            ]
        ),
        PluginMaintenanceOperation(
            name: cluster,
            appliesTo: [.table, .materializedView],
            scope: .object
        )
    ]

    /// A nil `schema` leaves the name unqualified, which is what a caller with no schema to offer
    /// means. Everything in the app does have one, and has to pass it: `search_path` resolves a bare
    /// name against `pg_temp` first, so a temp table of the same name is what got maintained.
    internal static func statements(
        operation: String,
        table: String?,
        schema: String?,
        options: [String: String],
        connectedDatabase: String?,
        capabilities: PostgreSQLCapabilities
    ) -> [String]? {
        let target = table.map { qualified(table: $0, schema: schema) }
        switch operation {
        case vacuum:
            var flags: [String] = []
            if isOn(options[fullKey]) { flags.append("FULL") }
            if isOn(options[analyzeKey]) { flags.append("ANALYZE") }
            if isOn(options[verboseKey]) { flags.append("VERBOSE") }
            let clause = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            return [target.map { "VACUUM\(clause) \($0)" } ?? "VACUUM\(clause)"]
        case analyze:
            return [target.map { "ANALYZE \($0)" } ?? "ANALYZE"]
        case reindex:
            guard let target else {
                return PostgreSQLVersionedStatements.reindexDatabase(
                    currentDatabase: connectedDatabase,
                    capabilities: capabilities
                ).map { [$0] }
            }
            let clause = isOn(options[verboseKey]) ? " (VERBOSE)" : ""
            return ["REINDEX\(clause) TABLE \(target)"]
        case cluster:
            return target.map { ["CLUSTER \($0)"] }
        default:
            return nil
        }
    }

    private static func qualified(table: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return PostgreSQLObjectQueries.quoteIdentifier(table) }
        return PostgreSQLObjectQueries.qualifiedName(schema: schema, name: table)
    }

    private static func isOn(_ value: String?) -> Bool {
        value == "true"
    }
}
