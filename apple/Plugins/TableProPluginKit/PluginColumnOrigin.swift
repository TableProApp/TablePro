import Foundation

// The table or view column a result column reads, as the engine resolved it, whatever the statement named the result.
public struct PluginColumnOrigin: Codable, Sendable, Hashable {
    public let schema: String?
    public let table: String
    public let column: String

    public init(schema: String?, table: String, column: String) {
        self.schema = schema
        self.table = table
        self.column = column
    }
}
