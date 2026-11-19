import Foundation

public struct PluginBatchStatement: Sendable {
    public let query: String
    // Nil sends the text as `execute(query:context:)` does, an array binds it as `executeParameterized` does.
    public let parameters: [PluginCellValue]?
    public let context: PluginStatementContext

    public init(query: String, parameters: [PluginCellValue]?, context: PluginStatementContext) {
        self.query = query
        self.parameters = parameters
        self.context = context
    }
}

// A statement's rows are read and dropped: a caller that needs them runs the statement on its own.
public enum PluginBatchStatementOutcome: Sendable {
    case succeeded(rowsAffected: Int, executionTime: TimeInterval)
    case failed(any Error)
}
