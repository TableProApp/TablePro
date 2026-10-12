//
//  OraclePartitionMappingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct OraclePartitionMappingTests {
    @Test("A partition states no bound, because HIGH_VALUE is a LONG column the driver cannot read")
    func partitionsCarryNoBound() {
        let mapped = OraclePartitionMapping.partitions(from: [
            OracleCatalogPartition(name: "P2024", position: 1, rowCount: 500),
            OracleCatalogPartition(name: "P2025", position: 2, rowCount: nil)
        ])

        #expect(mapped.map(\.name) == ["P2024", "P2025"])
        #expect(mapped.allSatisfy { $0.bound == nil })
        #expect(mapped.map(\.ordinalPosition) == [1, 2])
        #expect(mapped.first?.rowCount == 500)
    }

    @Test("No Oracle partition is a relation, so none offers to be opened or dropped by name")
    func partitionsAreNeverRelations() {
        let mapped = OraclePartitionMapping.partitions(from: [
            OracleCatalogPartition(name: "P1", position: 1, rowCount: nil)
        ])

        #expect(mapped.allSatisfy { !$0.isSeparateRelation })
        #expect(mapped.allSatisfy { $0.schema == nil })
    }

    @Test("A subpartition follows the partition it subdivides and names it")
    func subpartitionsNestUnderTheirPartition() {
        let mapped = OraclePartitionMapping.partitions(from: [
            OracleCatalogPartition(
                name: "P1",
                position: 1,
                rowCount: nil,
                subpartitions: [
                    OracleCatalogPartition(name: "P1_SP1", position: 1, rowCount: 10),
                    OracleCatalogPartition(name: "P1_SP2", position: 2, rowCount: 20)
                ]
            ),
            OracleCatalogPartition(name: "P2", position: 2, rowCount: nil)
        ])

        #expect(mapped.map(\.name) == ["P1", "P1_SP1", "P1_SP2", "P2"])
        #expect(mapped[0].isSubpartitioned)
        #expect(mapped[1].parentPartitionName == "P1")
        #expect(mapped[2].parentPartitionName == "P1")
        #expect(mapped[3].parentPartitionName == nil)
        #expect(!mapped[3].isSubpartitioned)
    }

    @Test("A table with no partitions maps to nothing rather than an empty placeholder row")
    func emptyCatalogMapsToNothing() {
        #expect(OraclePartitionMapping.partitions(from: []).isEmpty)
    }
}
