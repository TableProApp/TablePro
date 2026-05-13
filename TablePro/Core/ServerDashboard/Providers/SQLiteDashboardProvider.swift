//
//  SQLiteDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct SQLiteDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.serverMetrics]

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        var metrics: [DashboardMetric] = []

        let pageCountResult = try await execute("PRAGMA page_count")
        let pageSizeResult = try await execute("PRAGMA page_size")

        let pageCount = pageCountResult.rows.first.flatMap { Int(value($0, at: 0)) } ?? 0
        let pageSize = pageSizeResult.rows.first.flatMap { Int(value($0, at: 0)) } ?? 0
        let dbSizeBytes = pageCount * pageSize

        metrics.append(DashboardMetric(
            id: "db_size",
            label: String(localized: "Database Size"),
            value: formatBytes(dbSizeBytes),
            unit: "",
            icon: "internaldrive"
        ))

        metrics.append(DashboardMetric(
            id: "page_count",
            label: String(localized: "Page Count"),
            value: "\(pageCount)",
            unit: "",
            icon: "doc"
        ))

        metrics.append(DashboardMetric(
            id: "page_size",
            label: String(localized: "Page Size"),
            value: formatBytes(pageSize),
            unit: "",
            icon: "square.grid.3x3"
        ))

        let journalResult = try await execute("PRAGMA journal_mode")
        if let row = journalResult.rows.first {
            metrics.append(DashboardMetric(
                id: "journal_mode",
                label: String(localized: "Journal Mode"),
                value: value(row, at: 0).uppercased(),
                unit: "",
                icon: "doc.text"
            ))
        }

        let cacheResult = try await execute("PRAGMA cache_size")
        if let row = cacheResult.rows.first {
            let cacheSize = value(row, at: 0)
            metrics.append(DashboardMetric(
                id: "cache_size",
                label: String(localized: "Cache Size"),
                value: cacheSize,
                unit: String(localized: "pages"),
                icon: "memorychip"
            ))
        }

        return metrics
    }
}

// MARK: - Helpers

private extension SQLiteDashboardProvider {
    func value(_ row: [PluginCellValue], at index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].asText ?? ""
    }

    func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1_024 {
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        }
        return "\(bytes) B"
    }
}
