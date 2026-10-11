//
//  TypesenseDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TypesenseDashboardProviderTests {
    private struct UnexpectedCommand: Error {
        let command: String
    }

    private static let metricsPayload = """
        {
          "system_memory_used_bytes": "536870912",
          "system_memory_total_bytes": "1073741824",
          "system_disk_used_bytes": "250000",
          "system_disk_total_bytes": "1000000"
        }
        """

    private func response(_ json: String) -> QueryResult {
        QueryResult(
            columns: ["response"],
            columnTypes: [],
            rows: [[PluginCellValue.text(json)]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    private func usedShare(_ fraction: Double) -> String {
        String(format: String(localized: "%@ used"), fraction.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test("Memory and disk use read as a percentage through the string catalog")
    func usedShareIsLocalized() async throws {
        let metrics = try await TypesenseDashboardProvider().fetchMetrics { command in
            switch command {
            case "GET /metrics.json":
                return response(Self.metricsPayload)
            case "GET /stats.json":
                return response("{}")
            default:
                throw UnexpectedCommand(command: command)
            }
        }
        let memory = try #require(metrics.first { $0.id == "system_memory" })
        let disk = try #require(metrics.first { $0.id == "system_disk" })
        #expect(memory.unit == usedShare(0.5))
        #expect(disk.unit == usedShare(0.25))
    }

    @Test("The used-share unit is a key in the app's string catalog")
    func usedShareKeyIsInTheCatalog() throws {
        let catalog = try #require(StringCatalog.loadAll().first { $0.name == "TablePro" })
        #expect(catalog.containsKey("%@ used"))
    }
}
