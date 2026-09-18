import Foundation
import TableProPluginKit

struct QueryHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let query: String
    let connectionId: UUID
    let databaseName: String
    let databaseType: DatabaseType
    let schemaName: String?
    let source: QueryHistorySource
    let statementType: QueryHistoryStatementType
    let executedAt: Date
    let executionTime: TimeInterval
    let rowCount: Int
    let wasSuccessful: Bool
    let errorMessage: String?

    /// Client-measured time to the first row, when the driver could see one.
    let firstRowTime: TimeInterval?

    /// Execution time as the engine reported it, when its protocol carries one.
    let serverTime: TimeInterval?

    init(
        id: UUID = UUID(),
        query: String,
        connectionId: UUID,
        databaseName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        source: QueryHistorySource,
        statementType: QueryHistoryStatementType? = nil,
        executedAt: Date = Date(),
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil,
        firstRowTime: TimeInterval? = nil,
        serverTime: TimeInterval? = nil
    ) {
        self.id = id
        self.query = query
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.databaseType = databaseType
        self.schemaName = schemaName
        self.source = source
        self.statementType = statementType ?? QueryHistoryStatementType.classify(query)
        self.executedAt = executedAt
        self.executionTime = executionTime
        self.rowCount = rowCount
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
        self.firstRowTime = firstRowTime
        self.serverTime = serverTime
    }

    var timing: PluginQueryTiming {
        PluginQueryTiming(total: executionTime, firstRow: firstRowTime, server: serverTime)
    }

    /// What the database itself spent, as opposed to the wire. This is what the insights panels
    /// rank on, so a query that is only slow to transfer stops reading as a slow query.
    var databaseTime: TimeInterval { timing.databaseTime }

    var formattedDatabaseTime: String {
        QueryDurationFormatter.string(from: databaseTime)
    }

    var cursor: QueryHistoryCursor {
        QueryHistoryCursor(executedAt: executedAt, id: id)
    }

    var hasKnownRowCount: Bool { rowCount >= 0 }

    var hasMeasuredDuration: Bool { executionTime > 0 }

    /// A file-backed database names itself with its whole path, which tells the reader nothing a
    /// row has room for. The file name is the part that identifies it.
    var databaseDisplayName: String {
        guard databaseName.contains("/") else { return databaseName }
        let fileName = (databaseName as NSString).lastPathComponent
        return fileName.isEmpty ? databaseName : fileName
    }

    var formattedExecutionTime: String {
        QueryDurationFormatter.string(from: executionTime)
    }

    var formattedRowCount: String {
        guard hasKnownRowCount else { return "–" }
        return String(
            format: String(localized: "%lld rows", comment: "Row count in query history, %lld is the number of rows"),
            rowCount
        )
    }

    var queryPreview: String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasSuffix(";") {
            trimmed += ";"
        }
        if (trimmed as NSString).length > 100 {
            return String(trimmed.prefix(100)) + "…"
        }
        return trimmed
    }

    var singleLinePreview: String {
        let collapsed = query
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if (collapsed as NSString).length > 160 {
            return String(collapsed.prefix(160)) + "…"
        }
        return collapsed
    }
}
