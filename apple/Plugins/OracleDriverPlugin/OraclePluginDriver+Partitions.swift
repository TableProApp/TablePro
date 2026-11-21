//
//  OraclePluginDriver+Partitions.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

nonisolated extension OraclePluginDriver {
    // Two statements: asked per partition, one timeout among hundreds of round trips would lose the whole answer.
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
