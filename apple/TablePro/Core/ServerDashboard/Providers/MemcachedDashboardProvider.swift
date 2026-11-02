//
//  MemcachedDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Server metrics for Memcached, read from `stats`, which the driver returns as a Name and Value grid.
struct MemcachedDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.serverMetrics]

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        let stats = Self.stats(from: try await execute("stats"))
        func number(_ name: String) -> Int64? { stats[name].flatMap { Int64($0) } }

        var metrics: [DashboardMetric] = []
        if let used = number("bytes") {
            let limit = number("limit_maxbytes") ?? 0
            metrics.append(DashboardMetric(
                id: "memory",
                label: String(localized: "Used Memory"),
                value: ByteSizeFormatting.string(bytes: used),
                unit: limit > 0 ? Self.share(used, of: limit) : "",
                icon: "memorychip"
            ))
        }
        if let items = stats["curr_items"] {
            metrics.append(DashboardMetric(
                id: "items", label: String(localized: "Items"), value: items, unit: "", icon: "key"
            ))
        }
        if let hits = number("get_hits"), let misses = number("get_misses") {
            let lookups = Double(hits + misses)
            metrics.append(DashboardMetric(
                id: "hit_ratio",
                label: String(localized: "Hit Ratio"),
                value: lookups > 0 ? String(format: "%.1f", Double(hits) / lookups * 100) : "0",
                unit: "%",
                icon: "bolt"
            ))
        }
        if let evictions = stats["evictions"] {
            metrics.append(DashboardMetric(
                id: "evictions", label: String(localized: "Evictions"), value: evictions, unit: "", icon: "arrow.uturn.left"
            ))
        }
        if let connections = stats["curr_connections"] {
            metrics.append(DashboardMetric(
                id: "connections",
                label: String(localized: "Connections"),
                value: connections,
                unit: "",
                icon: "person.2"
            ))
        }
        if let uptime = number("uptime") {
            metrics.append(DashboardMetric(
                id: "uptime",
                label: String(localized: "Uptime"),
                value: DurationFormatting.string(seconds: Int(uptime)),
                unit: "",
                icon: "clock"
            ))
        }
        return metrics
    }

    func acceptsProcessId(_ processId: String) -> Bool {
        false
    }

    private static func stats(from result: QueryResult) -> [String: String] {
        var stats: [String: String] = [:]
        for row in result.rows where row.count >= 2 {
            if let name = row[0].asText { stats[name] = row[1].asText }
        }
        return stats
    }

    private static func share(_ used: Int64, of limit: Int64) -> String {
        let share = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(0)))
        return String(format: String(localized: "%@ used"), share)
    }
}
