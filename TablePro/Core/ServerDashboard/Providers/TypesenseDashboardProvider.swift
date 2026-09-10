//
//  TypesenseDashboardProvider.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Server metrics for Typesense, read from `/metrics.json` and `/stats.json`.
///
/// Every other provider sends SQL. This one sends the driver's own console syntax, which is what
/// `execute` takes on a Typesense connection, and reads the pretty-printed JSON the driver returns
/// in a single `response` cell.
struct TypesenseDashboardProvider: ServerDashboardQueryProvider {
    let supportedPanels: Set<DashboardPanel> = [.serverMetrics]

    func fetchMetrics(execute: (String) async throws -> QueryResult) async throws -> [DashboardMetric] {
        let metrics = try await json(from: execute("GET /metrics.json"))
        let stats = try await json(from: execute("GET /stats.json"))

        var result: [DashboardMetric] = []

        if let used = bytes(metrics, "system_memory_used_bytes"),
           let total = bytes(metrics, "system_memory_total_bytes"), total > 0 {
            result.append(DashboardMetric(
                id: "system_memory",
                label: String(localized: "System Memory"),
                value: "\(ByteSizeFormatting.string(bytes: used)) / \(ByteSizeFormatting.string(bytes: total))",
                unit: percent(used, of: total),
                icon: "memorychip"
            ))
        }

        if let resident = bytes(metrics, "typesense_memory_resident_bytes") {
            result.append(DashboardMetric(
                id: "typesense_memory",
                label: String(localized: "Typesense Memory"),
                value: ByteSizeFormatting.string(bytes: resident),
                unit: "",
                icon: "cpu"
            ))
        }

        if let ratio = number(metrics, "typesense_memory_fragmentation_ratio") {
            result.append(DashboardMetric(
                id: "fragmentation",
                label: String(localized: "Memory Fragmentation"),
                value: String(format: "%.2f", ratio),
                unit: "",
                icon: "square.split.diagonal"
            ))
        }

        if let used = bytes(metrics, "system_disk_used_bytes"),
           let total = bytes(metrics, "system_disk_total_bytes"), total > 0 {
            result.append(DashboardMetric(
                id: "system_disk",
                label: String(localized: "Disk"),
                value: "\(ByteSizeFormatting.string(bytes: used)) / \(ByteSizeFormatting.string(bytes: total))",
                unit: percent(used, of: total),
                icon: "internaldrive"
            ))
        }

        result += requestMetrics(stats)
        return result
    }

    // MARK: - Stats

    private func requestMetrics(_ stats: [String: Any]) -> [DashboardMetric] {
        var result: [DashboardMetric] = []

        if let total = number(stats, "total_requests_per_second") {
            result.append(DashboardMetric(
                id: "requests_per_second",
                label: String(localized: "Requests"),
                value: String(format: "%.1f", total),
                unit: String(localized: "per second"),
                icon: "arrow.left.arrow.right"
            ))
        }

        if let latency = number(stats, "search_latency_ms") {
            result.append(DashboardMetric(
                id: "search_latency",
                label: String(localized: "Search Latency"),
                value: String(format: "%.0f", latency),
                unit: "ms",
                icon: "timer"
            ))
        }

        if let latency = number(stats, "write_latency_ms") {
            result.append(DashboardMetric(
                id: "write_latency",
                label: String(localized: "Write Latency"),
                value: String(format: "%.0f", latency),
                unit: "ms",
                icon: "square.and.pencil"
            ))
        }

        if let pending = number(stats, "pending_write_batches") {
            result.append(DashboardMetric(
                id: "pending_writes",
                label: String(localized: "Pending Write Batches"),
                value: String(format: "%.0f", pending),
                unit: "",
                icon: "tray.full"
            ))
        }

        if let ratio = number(stats, "cache_hit_ratio") {
            result.append(DashboardMetric(
                id: "cache_hit_ratio",
                label: String(localized: "Cache Hit Ratio"),
                value: String(format: "%.0f", ratio * 100),
                unit: "%",
                icon: "bolt.horizontal"
            ))
        }

        return result
    }

    // MARK: - Reading the response

    /// The console renders a JSON object that is not a search result as one `response` cell of
    /// pretty-printed text, so the payload has to be parsed back out of it.
    private func json(from result: QueryResult) throws -> [String: Any] {
        guard let text = result.rows.first?.first?.asText,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Typesense reports byte counters as strings and ratios as numbers, in the same document.
    private func bytes(_ payload: [String: Any], _ key: String) -> Int? {
        if let text = payload[key] as? String { return Int(text) }
        if let value = payload[key] as? NSNumber { return value.intValue }
        return nil
    }

    private func number(_ payload: [String: Any], _ key: String) -> Double? {
        if let value = payload[key] as? NSNumber { return value.doubleValue }
        if let text = payload[key] as? String { return Double(text) }
        return nil
    }

    private func percent(_ used: Int, of total: Int) -> String {
        String(format: "%.0f%% used", Double(used) / Double(total) * 100)
    }
}
