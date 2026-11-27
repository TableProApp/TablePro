//
//  OraclePartitionMapping.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated internal struct OracleCatalogPartition: Equatable {
    internal let name: String
    internal let position: Int?
    internal let rowCount: Int?
    internal let subpartitions: [OracleCatalogPartition]

    internal init(name: String, position: Int?, rowCount: Int?, subpartitions: [OracleCatalogPartition] = []) {
        self.name = name
        self.position = position
        self.rowCount = rowCount
        self.subpartitions = subpartitions
    }
}

// A partition is a segment of one table, with no schema or name to open, drop or rename. It carries its position:
// `PluginPartitionInfo` has no field for a bound.
nonisolated internal enum OraclePartitionMapping {
    internal static func partitions(from catalog: [OracleCatalogPartition]) -> [PluginPartitionInfo] {
        catalog.flatMap { partition -> [PluginPartitionInfo] in
            let parent = PluginPartitionInfo(
                name: partition.name,
                ordinalPosition: partition.position,
                rowCount: partition.rowCount,
                relationType: nil,
                isSubpartitioned: !partition.subpartitions.isEmpty
            )
            let children = partition.subpartitions.map { subpartition in
                PluginPartitionInfo(
                    name: subpartition.name,
                    ordinalPosition: subpartition.position,
                    rowCount: subpartition.rowCount,
                    relationType: nil,
                    parentPartitionName: partition.name
                )
            }
            return [parent] + children
        }
    }
}
