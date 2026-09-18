//
//  OraclePluginDriver+Partitions.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

extension OraclePluginDriver {
    /// Two statements whatever the table holds: the partitions, then every subpartition of the
    /// table at once, grouped by the parent name `ALL_TAB_SUBPARTITIONS` carries. Asking per
    /// partition instead would be one round trip each, and one timeout among hundreds would
    /// discard the whole answer.
    ///
    /// The shape of the result is `OraclePartitionMapping`'s, not this file's: OracleNIO cannot be
    /// built with the current toolchain, so nothing that imports it is compile-checked on a
    /// developer Mac, and this extension stays thin enough that reading it is the whole review.
    func fetchPartitionDetails(table: String, schema: String?) async throws -> [PluginPartitionInfo] {
        let owner = effectiveSchema(schema)
        let result = try await rawQuery(OracleSchemaQueries.partitions(schema: owner, table: table))
        let partitions = result.rows.compactMap(OracleSchemaQueries.parsePartitionRow)
        guard !partitions.isEmpty else { return [] }

        var subpartitionsByParent: [String: [OracleCatalogPartition]] = [:]
        if partitions.contains(where: \.isSubpartitioned) {
            let subResult = try await rawQuery(OracleSchemaQueries.subpartitions(schema: owner, table: table))
            for entry in subResult.rows.compactMap(OracleSchemaQueries.parseSubpartitionRow) {
                subpartitionsByParent[entry.parent, default: []].append(
                    OracleCatalogPartition(
                        name: entry.row.name,
                        position: entry.row.position,
                        rowCount: entry.row.rowCount
                    )
                )
            }
        }

        return OraclePartitionMapping.partitions(
            from: partitions.map { partition in
                OracleCatalogPartition(
                    name: partition.name,
                    position: partition.position,
                    rowCount: partition.rowCount,
                    subpartitions: subpartitionsByParent[partition.name] ?? []
                )
            }
        )
    }
}
