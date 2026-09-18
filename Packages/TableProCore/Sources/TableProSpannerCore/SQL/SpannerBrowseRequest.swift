import Foundation

public struct SpannerBrowseFilter: Codable, Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?
    public let caseSensitive: Bool

    public init(column: String, op: String, value: String, secondValue: String? = nil, caseSensitive: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.secondValue = secondValue
        self.caseSensitive = caseSensitive
    }
}

public struct SpannerBrowseSort: Codable, Sendable, Equatable {
    public let column: String
    public let ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct SpannerBrowseRequest: Codable, Sendable, Equatable {
    public static let tag = "SPANNER_BROWSE:"

    public let table: String
    public let schema: String
    public let columns: [String]
    public let sorts: [SpannerBrowseSort]
    public let filters: [SpannerBrowseFilter]
    public let matchAll: Bool
    public let limit: Int
    public let offset: Int

    public init(
        table: String,
        schema: String,
        columns: [String] = [],
        sorts: [SpannerBrowseSort] = [],
        filters: [SpannerBrowseFilter] = [],
        matchAll: Bool = true,
        limit: Int,
        offset: Int
    ) {
        self.table = table
        self.schema = schema
        self.columns = columns
        self.sorts = sorts
        self.filters = filters
        self.matchAll = matchAll
        self.limit = limit
        self.offset = offset
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return Self.tag }
        return Self.tag + data.base64EncodedString()
    }

    public static func decode(_ text: String) -> SpannerBrowseRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(tag),
              let data = Data(base64Encoded: String(trimmed.dropFirst(tag.count)))
        else {
            return nil
        }
        return try? JSONDecoder().decode(SpannerBrowseRequest.self, from: data)
    }
}
