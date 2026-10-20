import Foundation

public struct SQLCompletionVocabulary: Sendable {
    public struct Operator: Sendable, Hashable {
        public let symbol: String
        public let summary: String
        public let appliesToTypes: [String]

        public init(symbol: String, summary: String, appliesToTypes: [String] = []) {
            self.symbol = symbol
            self.summary = summary
            self.appliesToTypes = appliesToTypes
        }
    }

    public struct StatementCompletion: Sendable, Hashable {
        public let label: String
        public let insertText: String

        public init(label: String, insertText: String) {
            self.label = label
            self.insertText = insertText
        }
    }

    public let functions: Set<String>
    public let functionNamesAreCaseInsensitive: Bool
    public let operators: [Operator]
    public let dataTypes: Set<String>
    // nil offers the generic options; an empty list offers none.
    public let tableOptions: [String]?
    public let statementCompletions: [StatementCompletion]

    public init(
        functions: Set<String> = [],
        functionNamesAreCaseInsensitive: Bool = false,
        operators: [Operator] = [],
        dataTypes: Set<String> = [],
        tableOptions: [String]? = nil,
        statementCompletions: [StatementCompletion] = []
    ) {
        self.functions = functions
        self.functionNamesAreCaseInsensitive = functionNamesAreCaseInsensitive
        self.operators = operators
        self.dataTypes = dataTypes
        self.tableOptions = tableOptions
        self.statementCompletions = statementCompletions
    }

    public static let generic = SQLCompletionVocabulary()
}
