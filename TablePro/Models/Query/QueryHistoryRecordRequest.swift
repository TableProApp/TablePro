import Foundation
import TableProPluginKit

struct QueryHistoryRecordRequest: Sendable {
    /// Chosen by the caller so a run that also saves a plan can link the two before either is
    /// written. Defaulted, so every other caller ignores it.
    var id = UUID()
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

    /// The EXPLAIN plan this run produced, when it is one worth keeping. Written after the history
    /// row and never inside its transaction, so a plan that cannot be stored never costs the run
    /// its place in history.
    var planCapture: QueryPlanCapture?

    /// What the elapsed time was spent on, when the driver could tell. Defaulted, because most
    /// recorders write a statement they timed themselves and have no split to offer.
    var timing: PluginQueryTiming?

    init(
        id: UUID = UUID(),
        query: String,
        connectionId: UUID,
        databaseName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        source: QueryHistorySource,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil,
        planCapture: QueryPlanCapture? = nil,
        timing: PluginQueryTiming? = nil
    ) {
        self.id = id
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
        self.planCapture = planCapture
        self.timing = timing
    }
}
