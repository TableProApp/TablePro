import Foundation

public struct SpannerRenderedStatement: Sendable, Equatable {
    public let sql: String
    public let parameters: [SpannerCell]
    public let parameterTypes: [SpannerType]?

    public init(sql: String, parameters: [SpannerCell] = [], parameterTypes: [SpannerType]? = nil) {
        self.sql = sql
        self.parameters = parameters
        self.parameterTypes = parameterTypes
    }
}

internal struct SpannerParameterList {
    private let dialect: SpannerDialect
    private(set) var values: [SpannerCell] = []

    init(dialect: SpannerDialect) {
        self.dialect = dialect
    }

    mutating func bind(_ value: SpannerCell) -> String {
        values.append(value)
        return dialect.placeholder(values.count)
    }

    mutating func bind(_ text: String) -> String {
        bind(.text(text))
    }
}
