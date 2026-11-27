//
//  ParquetStagingMemoryTests.swift
//  FormatPluginTests
//

import Foundation
import Testing

struct ParquetStagingMemoryTests {
    private static let gibibyte: UInt64 = 1 << 30

    @Test(
        "The staging limit is a sixteenth of the machine's memory, from 1 to 4 GiB",
        arguments: [
            (physical: UInt64(4), limitMiB: UInt64(1_024)),
            (physical: 8, limitMiB: 1_024),
            (physical: 16, limitMiB: 1_024),
            (physical: 24, limitMiB: 1_536),
            (physical: 32, limitMiB: 2_048),
            (physical: 64, limitMiB: 4_096),
            (physical: 512, limitMiB: 4_096)
        ]
    )
    func limitFollowsPhysicalMemory(physical: UInt64, limitMiB: UInt64) {
        let limit = ParquetStaging.memoryLimit(physicalMemory: physical * Self.gibibyte)

        #expect(limit == limitMiB << 20)
        #expect(ParquetStaging.memoryLimitSetting(bytes: limit) == "\(limitMiB)MiB")
    }

    @Test("Spilling may take a quarter of the free disk")
    func spillBudgetIsAQuarterOfTheFreeDisk() {
        #expect(ParquetStaging.spillBudget(freeDiskBytes: 40 * Self.gibibyte) == 10 * Self.gibibyte)
        #expect(ParquetStaging.spillBudget(freeDiskBytes: 0) == 0)
    }

    @Test(
        "The budget counts what is spilled and what is about to arrive",
        arguments: [
            (spilled: UInt64(0), incoming: UInt64(10), budget: UInt64(100), isSpent: false),
            (spilled: 89, incoming: 10, budget: 100, isSpent: false),
            (spilled: 90, incoming: 10, budget: 100, isSpent: true),
            (spilled: 100, incoming: 0, budget: 100, isSpent: true),
            (spilled: 0, incoming: 500, budget: 100, isSpent: true),
            (spilled: 0, incoming: 0, budget: 0, isSpent: true)
        ]
    )
    func budgetCountsSpilledAndIncoming(spilled: UInt64, incoming: UInt64, budget: UInt64, isSpent: Bool) {
        #expect(ParquetStaging.spillBudgetIsSpent(spilled: spilled, incoming: incoming, budget: budget) == isSpent)
    }

    @Test("Bytes in a text column keep DuckDB's blob spelling")
    func bytesKeepTheBlobSpelling() {
        let data = Data([0x41, 0x7E, 0x20, 0x5C, 0x27, 0x22, 0x00, 0x7F, 0xFF])

        #expect(ParquetStaging.text(forBytes: data) == #"A~ \x5C\x27\x22\x00\x7F\xFF"#)
    }
}
