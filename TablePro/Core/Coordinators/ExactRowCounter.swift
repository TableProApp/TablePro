import Foundation
import os
import TableProPluginKit

internal enum ExactRowCounter {
    internal enum Route: Equatable {
        case driverCount
        case hostCountSQL(String)
        case driverCountThenHostSQL(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ExactRowCounter")

    internal static func route(countSQL: String?, driverOwnsQueryBuilding: Bool) -> Route {
        guard let countSQL else { return .driverCount }
        return driverOwnsQueryBuilding ? .driverCountThenHostSQL(countSQL) : .hostCountSQL(countSQL)
    }

    internal static func count(
        on driver: DatabaseDriver,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode,
        countSQL: String?
    ) async throws -> Int? {
        let ownsQueryBuilding = driver.queryBuildingPluginDriver != nil
        switch route(countSQL: countSQL, driverOwnsQueryBuilding: ownsQueryBuilding) {
        case .driverCount:
            return try await driver.fetchExactRowCount(table: table, filters: filters, logicMode: logicMode)
        case .hostCountSQL(let sql):
            return try await hostCount(sql, on: driver)
        case .driverCountThenHostSQL(let sql):
            if let counted = try await driverCountAllowingFallback(
                on: driver, table: table, filters: filters, logicMode: logicMode
            ) {
                return counted
            }
            return try await hostCount(sql, on: driver)
        }
    }

    private static func driverCountAllowingFallback(
        on driver: DatabaseDriver,
        table: String,
        filters: [TableFilter],
        logicMode: FilterLogicMode
    ) async throws -> Int? {
        do {
            return try await driver.fetchExactRowCount(table: table, filters: filters, logicMode: logicMode)
        } catch {
            try Task.checkCancellation()
            logger.warning("Driver count failed, falling back to COUNT(*): \(error.localizedDescription)")
            return nil
        }
    }

    private static func hostCount(_ sql: String, on driver: DatabaseDriver) async throws -> Int? {
        let result = try await driver.execute(query: sql)
        guard let countText = result.rows.first?.first?.asText else { return nil }
        return Int(countText)
    }
}
