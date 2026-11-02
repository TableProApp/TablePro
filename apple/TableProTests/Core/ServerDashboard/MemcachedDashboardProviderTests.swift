//
//  MemcachedDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MemcachedDashboardProviderTests {
    private static func stats(_ pairs: [(String, String)]) -> QueryResult {
        QueryResult(
            columns: ["Name", "Value"],
            columnTypes: [],
            rows: pairs.map { [.text($0.0), .text($0.1)] },
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    @Test("Metrics come from one stats call")
    func metricsFromStats() async throws {
        var commands: [String] = []
        let metrics = try await MemcachedDashboardProvider().fetchMetrics { command in
            commands.append(command)
            return Self.stats([
                ("uptime", "3600"), ("curr_connections", "4"), ("curr_items", "12"), ("bytes", "1048576"),
                ("limit_maxbytes", "67108864"), ("get_hits", "3"), ("get_misses", "1"), ("evictions", "0"),
            ])
        }
        #expect(commands == ["stats"])
        let byId = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        #expect(byId["items"]?.value == "12")
        #expect(byId["hit_ratio"]?.value == "75.0")
        #expect(byId["connections"]?.value == "4")
        #expect(byId["evictions"]?.value == "0")
        #expect(byId["memory"] != nil)
        #expect(byId["uptime"] != nil)
    }

    @Test("No lookups yet reads as a 0 hit ratio, and missing stats are left out")
    func sparseStats() async throws {
        let metrics = try await MemcachedDashboardProvider().fetchMetrics { _ in
            Self.stats([("get_hits", "0"), ("get_misses", "0")])
        }
        #expect(metrics.map(\.id) == ["hit_ratio"])
        #expect(metrics.first?.value == "0")
    }
}
