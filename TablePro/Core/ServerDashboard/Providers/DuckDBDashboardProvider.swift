//
//  DuckDBDashboardProvider.swift
//  TablePro
//

import Foundation

struct DuckDBDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.serverMetrics]

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let sizeResult = try await execute("SELECT * FROM pragma_database_size()")
        if let row = sizeResult.rows.first {
            let col = columnIndex(from: sizeResult.columns)
            let dbSize = value(row, at: col["database_size"])
            let blockSize = value(row, at: col["block_size"])
            let totalBlocks = value(row, at: col["total_blocks"])

            if !dbSize.isEmpty {
                metrics.append(DashboardMetric(
                    id: "db_size",
                    label: String(localized: "Database Size"),
                    value: dbSize,
                    unit: "",
                    icon: "internaldrive"
                ))
            }
            if !blockSize.isEmpty {
                metrics.append(DashboardMetric(
                    id: "block_size",
                    label: String(localized: "Block Size"),
                    value: blockSize,
                    unit: "",
                    icon: "square.grid.3x3"
                ))
            }
            if !totalBlocks.isEmpty {
                metrics.append(DashboardMetric(
                    id: "total_blocks",
                    label: String(localized: "Total Blocks"),
                    value: totalBlocks,
                    unit: "",
                    icon: "cube"
                ))
            }
        }

        let settingsResult = try await execute("""
            SELECT current_setting('memory_limit') AS memory_limit,
                   current_setting('threads') AS threads
            """)
        if let row = settingsResult.rows.first {
            let col = columnIndex(from: settingsResult.columns)
            let memLimit = value(row, at: col["memory_limit"])
            let threads = value(row, at: col["threads"])

            if !memLimit.isEmpty {
                metrics.append(DashboardMetric(
                    id: "memory_limit",
                    label: String(localized: "Memory Limit"),
                    value: memLimit,
                    unit: "",
                    icon: "memorychip"
                ))
            }
            if !threads.isEmpty {
                metrics.append(DashboardMetric(
                    id: "threads",
                    label: String(localized: "Threads"),
                    value: threads,
                    unit: "",
                    icon: "cpu"
                ))
            }
        }

        return metrics
    }
}

// MARK: - Helpers

private extension DuckDBDashboardProvider {
    func columnIndex(from columns: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in columns.enumerated() {
            map[name.lowercased()] = index
        }
        return map
    }

    func value(_ row: [String?], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index] ?? ""
    }
}
