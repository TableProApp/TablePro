//
//  MemoryPressureAdvisor.swift
//  TablePro
//

import Foundation

import os

/// Advises on tab eviction budget based on system memory and pressure state.
@MainActor
internal enum MemoryPressureAdvisor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MemoryPressureAdvisor")

    /// Current memory pressure level from the OS dispatch source.
    private(set) static var isUnderPressure = false

    private static let pressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: .main
        )
        source.setEventHandler {
            let event = source.data
            let wasPressured = isUnderPressure
            isUnderPressure = event.contains(.warning) || event.contains(.critical)
            if isUnderPressure && !wasPressured {
                logger.info("Memory pressure detected — reducing tab eviction budget")
            } else if !isUnderPressure && wasPressured {
                logger.info("Memory pressure resolved — restoring tab eviction budget")
            }
        }
        source.activate()
        return source
    }()

    /// Call once at app launch to start monitoring memory pressure.
    internal static func startMonitoring() {
        _ = pressureSource
    }

    internal static func budgetForInactiveTabs() -> Int {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let gb: UInt64 = 1_073_741_824

        let baseBudget: Int
        if totalBytes >= 32 * gb {
            baseBudget = 8
        } else if totalBytes >= 16 * gb {
            baseBudget = 5
        } else if totalBytes >= 8 * gb {
            baseBudget = 3
        } else {
            baseBudget = 2
        }

        // Halve the budget under memory pressure
        return isUnderPressure ? max(1, baseBudget / 2) : baseBudget
    }

    internal static func estimatedFootprint(rowCount: Int, columnCount: Int) -> Int {
        rowCount * columnCount * 64
    }
}
