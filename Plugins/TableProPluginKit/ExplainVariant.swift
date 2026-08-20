import Foundation

public struct ExplainVariant: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let sqlPrefix: String
    public let format: ExplainPlanFormat

    public init(id: String, label: String, sqlPrefix: String, format: ExplainPlanFormat = .plainText) {
        self.id = id
        self.label = label
        self.sqlPrefix = sqlPrefix
        self.format = format
    }

    @_disfavoredOverload
    public init(id: String, label: String, sqlPrefix: String) {
        self.init(id: id, label: label, sqlPrefix: sqlPrefix, format: .plainText)
    }
}
