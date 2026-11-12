import Foundation

public struct FirebaseFilterSpec: Codable, Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?

    public init(column: String, op: String, value: String, secondValue: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
    }

    /// The host sends BETWEEN as `value: "lower,upper"` with the upper bound again in `secondValue`,
    /// so the lower bound is `value` without that suffix, whatever commas the bounds hold.
    public var betweenBounds: (lower: String, upper: String)? {
        guard let upper = secondValue else {
            let parts = FirebaseScalars.split(value, separator: ",", omittingEmpty: false)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let suffix = Array(("," + upper).unicodeScalars)
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= suffix.count, Array(scalars.suffix(suffix.count)) == suffix else {
            return (value, upper)
        }
        var lower = String.UnicodeScalarView()
        lower.append(contentsOf: scalars.dropLast(suffix.count))
        return (String(lower), upper)
    }
}

public struct FirebaseSortSpec: Codable, Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

/// Turned into a query only when it runs, because filter values are typed by the fields the
/// collection was last seen holding.
public struct FirebaseBrowseSpec: Codable, Sendable, Equatable {
    public let table: String
    public let filters: [FirebaseFilterSpec]
    public let logicMode: String
    public let sorts: [FirebaseSortSpec]
    public let limit: Int
    public let offset: Int

    public init(
        table: String,
        filters: [FirebaseFilterSpec] = [],
        logicMode: String = "AND",
        sorts: [FirebaseSortSpec] = [],
        limit: Int,
        offset: Int
    ) {
        self.table = table
        self.filters = filters
        self.logicMode = logicMode
        self.sorts = sorts
        self.limit = limit
        self.offset = offset
    }

    public var usesOr: Bool {
        logicMode.uppercased() == "OR"
    }
}
