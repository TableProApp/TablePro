import Foundation

public struct ExplainVariant: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let sqlPrefix: String

    public init(id: String, label: String, sqlPrefix: String) {
        self.id = id
        self.label = label
        self.sqlPrefix = sqlPrefix
    }
}
