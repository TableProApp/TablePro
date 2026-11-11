//
//  BulkReadTimeout.swift
//  TablePro
//

import Foundation
import os

// A driver's row stream waits for its reader, so a bulk read lasts as long as the copy, transfer or compare consuming
// it, and the session's interactive query timeout would end it part way. The export lifts the timeout the same way.
enum BulkReadTimeout {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BulkReadTimeout")

    static func lifted<T: Sendable>(
        on drivers: [DatabaseDriver],
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        var restored: [(DatabaseDriver, Int)] = []
        for driver in drivers {
            restored.append((driver, await restoredSeconds(for: driver)))
            await apply(0, on: driver)
        }
        do {
            let value = try await operation()
            await restore(restored)
            return value
        } catch {
            await restore(restored)
            throw error
        }
    }

    // In a task of its own, so a Stop that cancelled the read still puts the timeout back on the pooled connection.
    private static func restore(_ timeouts: [(DatabaseDriver, Int)]) async {
        await Task {
            for (driver, seconds) in timeouts { await apply(seconds, on: driver) }
        }.value
    }

    static func restoredSeconds(for driver: DatabaseDriver) async -> Int {
        if let adapter = driver as? PluginDriverAdapter { return adapter.effectiveQueryTimeoutSeconds }
        let configured = driver.connection.queryTimeoutSeconds
        return await MainActor.run {
            ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                configuredSeconds: configured,
                globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
            )
        }
    }

    private static func apply(_ seconds: Int, on driver: DatabaseDriver) async {
        do {
            try await driver.applyQueryTimeout(seconds)
        } catch {
            logger.warning("Query timeout \(seconds) not applied for a bulk read: \(error.localizedDescription, privacy: .private)")
        }
    }
}
