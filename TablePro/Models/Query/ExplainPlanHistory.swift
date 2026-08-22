import Foundation

struct ExplainPlanHistoryContext: Hashable, Sendable {
    let historyId: UUID
    let subjectQuery: String
    let connectionId: UUID
    let databaseName: String
    let databaseType: DatabaseType
    let schemaName: String?
    let variantId: String?
    let formatRawValue: String
    let capturedAt: Date
}

struct ExplainPlanHistoryRecord: Hashable, Sendable {
    static let maximumRawByteCount = 2_000_000
    static let maximumTotalRawByteCount: Int64 = 100_000_000
    static let maximumStoredSnapshotCount = 1_000

    let context: ExplainPlanHistoryContext
    let rawText: String
    let rawByteCount: Int
    let parserSchemaVersion: Int

    init(
        context: ExplainPlanHistoryContext,
        rawText: String,
        parserSchemaVersion: Int = 1
    ) {
        self.context = context
        self.rawText = rawText
        self.rawByteCount = rawText.utf8.count
        self.parserSchemaVersion = parserSchemaVersion
    }

    var isWithinStorageLimit: Bool {
        rawByteCount <= Self.maximumRawByteCount
    }
}

struct ExplainPlanHistoryCapture: Sendable {
    let context: ExplainPlanHistoryContext
    let record: ExplainPlanHistoryRecord

    static func make(
        context: ExplainPlanHistoryContext,
        rawText: String
    ) -> ExplainPlanHistoryCapture {
        ExplainPlanHistoryCapture(
            context: context,
            record: ExplainPlanHistoryRecord(context: context, rawText: rawText)
        )
    }

    static func make(
        context: ExplainPlanHistoryContext,
        rawText: String,
        queryParameters: [QueryParameter]?
    ) -> ExplainPlanHistoryCapture? {
        guard queryParameters == nil else { return nil }
        return make(context: context, rawText: rawText)
    }
}

struct ExplainPlanHistorySnapshot: Identifiable, Hashable, Sendable {
    var id: UUID { context.historyId }

    let context: ExplainPlanHistoryContext
    let executionTime: TimeInterval
}
