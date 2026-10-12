//
//  OraclePartitionMapping.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

/// One partition as the catalog reports it, before it becomes a transfer type.
///
/// It takes plain values rather than `OraclePartitionRow` so this file compiles without
/// `TableProOracleCore`, and therefore without OracleNIO. That matters: OracleNIO cannot be built
/// with the current toolchain, so anything that imports it cannot be compile-checked or tested here
/// at all. Keeping the shape of the list out of the driver is what lets it be.
internal struct OracleCatalogPartition: Equatable {
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

/// An Oracle partition is a segment of one table rather than a relation of its own, so it carries no
/// schema and cannot be opened, dropped or renamed by name.
///
/// It states no bound either: `ALL_TAB_PARTITIONS.HIGH_VALUE` is a `LONG` column, the datatype this
/// driver already avoids because OracleNIO cannot decode it, so the row carries its position.
internal enum OraclePartitionMapping {
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
