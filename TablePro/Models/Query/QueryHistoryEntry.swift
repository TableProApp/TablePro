//
//  QueryHistoryEntry.swift
//  TablePro
//
//  Query history entry model
//

import Foundation

/// Represents a single query execution in history
struct QueryHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let query: String
    let connectionId: UUID
    let databaseName: String
    let executedAt: Date
    let executionTime: TimeInterval
    let rowCount: Int  // -1 if unknown
    let wasSuccessful: Bool
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        query: String,
        connectionId: UUID,
        databaseName: String,
        executedAt: Date = Date(),
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.query = query
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.executedAt = executedAt
        self.executionTime = executionTime
        self.rowCount = rowCount
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
    }

    /// Formatted execution time for display
    var formattedExecutionTime: String {
        if executionTime < 1.0 {
            return String(format: "%.0f ms", executionTime * 1_000)
        } else {
            return String(format: "%.2f s", executionTime)
        }
    }

    /// Formatted row count for display
    var formattedRowCount: String {
        if rowCount < 0 {
            return "–"
        } else if rowCount == 1 {
            return "1 row"
        } else {
            return "\(rowCount) rows"
        }
    }

    /// Truncated query for preview (first 100 chars)
    var queryPreview: String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasSuffix(";") {
            trimmed += ";"
        }
        if (trimmed as NSString).length > 100 {
            return String(trimmed.prefix(100)) + "..."
        }
        return trimmed
    }
}
