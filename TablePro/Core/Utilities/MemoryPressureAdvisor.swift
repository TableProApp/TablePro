//
//  MemoryPressureAdvisor.swift
//  TablePro
//

import Foundation

/// Advises on tab eviction budget based on system memory.
enum MemoryPressureAdvisor {
    /// Returns the number of inactive tabs that should be kept in memory.
    /// Scales with total physical memory since macOS manages virtual memory pressure.
    static func budgetForInactiveTabs() -> Int {
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

    /// Rough estimate of a tab's memory footprint in bytes.
    /// Uses 64 bytes per cell as average (16B String struct + ~48B backing store).
    static func estimatedFootprint(rowCount: Int, columnCount: Int) -> Int {
        rowCount * columnCount * 64
    }
}
