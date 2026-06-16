import Foundation

public struct PluginTriggerInfo: Codable, Sendable {
    public let name: String
    public let timing: String
    public let event: String
    public let forEachRow: Bool
    public let whenClause: String?
    public let statement: String

    public init(
        name: String,
        timing: String,
        event: String,
        forEachRow: Bool = true,
        whenClause: String? = nil,
        statement: String
    ) {
        self.name = name
        self.timing = timing
        self.event = event
        self.forEachRow = forEachRow
        self.whenClause = whenClause
        self.statement = statement
    }
}
