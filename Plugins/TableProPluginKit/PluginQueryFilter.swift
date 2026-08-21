import Foundation

public struct PluginQueryFilter: Sendable {
    public let column: String
    public let op: String
    public let value: String
    public let isCaseSensitive: Bool

    /// The upper bound of a two-sided operator such as `BETWEEN`, carried separately so a value
    /// holding a comma cannot be mistaken for the separator between the two bounds.
    public let secondValue: String?

    /// The array ancestor this condition binds to, for a driver whose query language can require
    /// several conditions to match the *same* array element. `nil` leaves the condition
    /// independent, which for a document store means any element may satisfy it.
    public let elementScope: String?

    @_disfavoredOverload
    public init(column: String, op: String, value: String, isCaseSensitive: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.isCaseSensitive = isCaseSensitive
        self.secondValue = nil
        self.elementScope = nil
    }

    public init(
        column: String,
        op: String,
        value: String,
        isCaseSensitive: Bool = true,
        secondValue: String?,
        elementScope: String?
    ) {
        self.column = column
        self.op = op
        self.value = value
        self.isCaseSensitive = isCaseSensitive
        self.secondValue = secondValue
        self.elementScope = elementScope
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
