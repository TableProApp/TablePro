//
//  ClickHouseDashboardProviderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ClickHouseDashboardProviderTests {
    private let provider = ClickHouseDashboardProvider(serverVersion: "24.8.1")

    // The TabSeparatedWithNamesAndTypes body system.processes answers with, as the driver hands it on.
    private static func processes(elapsed: String) -> QueryResult {
        QueryResult(
            columns: ["query_id", "user", "current_database", "elapsed", "read_rows", "memory_usage", "query"],
            columnTypes: [],
            rows: [[
                "0c1f4a52-7d3e-4b8a-9f10-2a6b5c7d8e9f", "default", "analytics", .text(elapsed), "81920", "4194304",
                "SELECT count() FROM events",
            ]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    // `query_duration_ms / 1000` from system.query_log, which ClickHouse answers as a Float64.
    private static func queryLog(durationSeconds: String) -> QueryResult {
        QueryResult(
            columns: ["user", "duration_secs", "query"],
            columnTypes: [],
            rows: [["default", .text(durationSeconds), "SELECT count() FROM events"]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
    }

    @Test("A session's elapsed time is cut to whole seconds")
    func elapsedIsCutToWholeSeconds() async throws {
        let sessions = try await provider.fetchSessions { _ in Self.processes(elapsed: "83.254913") }
        #expect(sessions.map(\.durationSeconds) == [83])
        #expect(sessions.first?.duration == DurationFormatting.string(seconds: 83))
    }

    @Test("An elapsed time that is not a number an Int holds is listed instead of crashing the refresh", arguments: [
        ("inf", Int.max), ("Infinity", .max), ("1e400", .max), ("1e30", .max), ("9.3e18", .max),
        ("-inf", .min), ("-1e30", .min), ("nan", 0), ("", 0), ("soon", 0),
    ] as [(String, Int)])
    func elapsedThatIsNotARepresentableNumber(elapsed: String, seconds: Int) async throws {
        let sessions = try await provider.fetchSessions { _ in Self.processes(elapsed: elapsed) }
        #expect(sessions.map(\.durationSeconds) == [seconds])
        #expect(sessions.first?.duration == DurationFormatting.string(seconds: seconds))
    }

    @Test("A slow query's fractional duration is cut to whole seconds, not read as zero", arguments: [
        ("1.5", 1), ("83.254913", 83), ("3600", 3_600), ("inf", Int.max), ("1e30", .max), ("nan", 0), ("", 0),
    ] as [(String, Int)])
    func slowQueryDurationIsAFloat(duration: String, seconds: Int) async throws {
        let slow = try await provider.fetchSlowQueries { _ in Self.queryLog(durationSeconds: duration) }
        #expect(slow.map(\.duration) == [DurationFormatting.string(seconds: seconds)])
        #expect(slow.first?.user == "default")
        #expect(slow.first?.query == "SELECT count() FROM events")
    }
}
