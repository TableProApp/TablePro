//
//  MemoryPressureAdvisor.swift
//  TablePro
//

import Foundation

/// Advises on tab eviction budget based on system memory.
internal enum MemoryPressureAdvisor {
    internal static func budgetForInactiveTabs() -> Int {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let gb: UInt64 = 1_073_741_824

        if totalBytes >= 32 * gb {
            return 8
        } else if totalBytes >= 16 * gb {
            return 5
        } else if totalBytes >= 8 * gb {
            return 3
        } else {
            return 2
        }
    }

    internal static func estimatedFootprint(rowCount: Int, columnCount: Int) -> Int {
        rowCount * columnCount * 64
    }
}
