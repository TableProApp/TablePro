import Foundation

public struct SpannerQueryOutcome: Sendable, Equatable {
    public let fields: [SpannerField]
    public let rows: [[SpannerCell]]
    public let rowsAffected: Int64?
    public let kind: SpannerStatementKind

    public init(fields: [SpannerField], rows: [[SpannerCell]], rowsAffected: Int64?, kind: SpannerStatementKind) {
        self.fields = fields
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.kind = kind
    }

    static func empty(_ kind: SpannerStatementKind) -> SpannerQueryOutcome {
        SpannerQueryOutcome(fields: [], rows: [], rowsAffected: nil, kind: kind)
    }

    static func resultSet(_ result: SpannerResultSet, kind: SpannerStatementKind) -> SpannerQueryOutcome {
        let fields = result.metadata?.fields ?? []
        return SpannerQueryOutcome(
            fields: fields,
            rows: SpannerValueDecoder.rows(result.rows, fields: fields),
            rowsAffected: result.stats?.rowCountExact ?? result.stats?.rowCountLowerBound,
            kind: kind
        )
    }
}

public enum SpannerStreamOutput: Sendable, Equatable {
    case header([SpannerField])
    case rows([[SpannerCell]])
}

public enum SpannerExecutionError: Error, Sendable, Equatable {
    case transactionAlreadyOpen
    case noTransactionOpen
    case transactionAborted
    case commitOutcomeUnknown
    case explainNotSupported(SpannerStatementKind)
    case explainAnalyzeNotSupported
    case unsupportedTransactionControl
    case schemaChangeStillRunning(operation: String)
    case parameterEncoding(SpannerParameterEncodingError)
    case parameterCount(found: Int, expected: Int)
    case closed
}
