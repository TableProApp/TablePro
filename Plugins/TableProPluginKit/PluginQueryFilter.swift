import Foundation

public struct PluginQueryFilter: Sendable {
    public let column: String
    public let op: String
    public let value: String
    public let isCaseSensitive: Bool

    public init(column: String, op: String, value: String, isCaseSensitive: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.isCaseSensitive = isCaseSensitive
    }

    public var asTuple: (column: String, op: String, value: String) {
        (column, op, value)
    }
}

public extension [PluginQueryFilter] {
    var asTuples: [(column: String, op: String, value: String)] {
        map(\.asTuple)
    }
}
