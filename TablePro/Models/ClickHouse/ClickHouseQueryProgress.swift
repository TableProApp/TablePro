//
//  ClickHouseQueryProgress.swift
//  TablePro
//
//  Query progress tracking data for ClickHouse queries.
//

import Foundation

/// Live query progress data polled from system.processes
struct ClickHouseQueryProgress: Equatable {
    let rowsRead: UInt64
    let bytesRead: UInt64
    let totalRowsToRead: UInt64
    let elapsedSeconds: Double

    /// Formatted string for live display during execution: "1.2M rows · 45 MB"
    var formattedLive: String {
        "\(Self.formatCount(rowsRead)) rows · \(Self.formatBytes(bytesRead))"
    }

    /// Formatted summary after completion: "235ms · 1.2M rows · 45 MB"
    var formattedSummary: String {
        "\(Self.formatDuration(elapsedSeconds)) · \(Self.formatCount(rowsRead)) rows · \(Self.formatBytes(bytesRead))"
    }

    // MARK: - Formatting Helpers

    private static func formatCount(_ count: UInt64) -> String {
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<1_000_000:
            let k = Double(count) / 1_000
            return String(format: "%.1fK", k)
        case 1_000_000..<1_000_000_000:
            let m = Double(count) / 1_000_000
            return String(format: "%.1fM", m)
        default:
            let b = Double(count) / 1_000_000_000
            return String(format: "%.1fB", b)
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        switch bytes {
        case 0..<1_024:
            return "\(bytes) B"
        case 1_024..<1_048_576:
            let kb = Double(bytes) / 1_024
            return String(format: "%.0f KB", kb)
        case 1_048_576..<1_073_741_824:
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.1f MB", mb)
        default:
            let gb = Double(bytes) / 1_073_741_824
            return String(format: "%.2f GB", gb)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 0.001 {
            return "<1ms"
        } else if seconds < 1.0 {
            return String(format: "%.0fms", seconds * 1_000)
        } else if seconds < 60.0 {
            return String(format: "%.2fs", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        }
    }
}
