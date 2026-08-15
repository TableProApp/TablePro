import Foundation

struct QueryHistoryRecordRequest: Sendable {
    let query: String
    let connectionId: UUID
    let databaseName: String
    let databaseType: DatabaseType
    var schemaName: String?
    let source: QueryHistorySource
    let executionTime: TimeInterval
    let rowCount: Int
    let wasSuccessful: Bool
    var errorMessage: String?

    init(
        query: String,
        connectionId: UUID,
        databaseName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        source: QueryHistorySource,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil
    ) {
        self.query = query
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.databaseType = databaseType
        self.schemaName = schemaName
        self.source = source
        self.executionTime = executionTime
        self.rowCount = rowCount
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
    }
}
