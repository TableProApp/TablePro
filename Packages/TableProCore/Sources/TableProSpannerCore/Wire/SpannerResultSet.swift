import Foundation

public struct SpannerResultSetMetadata: Decodable, Sendable, Equatable {
    public let fields: [SpannerField]
    public let transactionId: String?
    public let undeclaredParameters: [SpannerField]

    public init(fields: [SpannerField], transactionId: String? = nil, undeclaredParameters: [SpannerField] = []) {
        self.fields = fields
        self.transactionId = transactionId
        self.undeclaredParameters = undeclaredParameters
    }

    private enum CodingKeys: String, CodingKey {
        case rowType
        case transaction
        case undeclaredParameters
    }

    private enum TransactionKeys: String, CodingKey {
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fields = try container.decodeIfPresent(SpannerFieldList.self, forKey: .rowType)?.fields ?? []
        undeclaredParameters = try container.decodeIfPresent(
            SpannerFieldList.self,
            forKey: .undeclaredParameters
        )?.fields ?? []
        transactionId = try Self.decodeTransactionId(container)
    }

    private static func decodeTransactionId(_ container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.transaction), try !container.decodeNil(forKey: .transaction) else { return nil }
        let transaction = try container.nestedContainer(keyedBy: TransactionKeys.self, forKey: .transaction)
        return try transaction.decodeIfPresent(String.self, forKey: .id)
    }
}

public struct SpannerPlanNode: Decodable, Sendable, Equatable {
    public struct ChildLink: Decodable, Sendable, Equatable {
        public let childIndex: Int
        public let type: String?
        public let variable: String?

        public init(childIndex: Int, type: String? = nil, variable: String? = nil) {
            self.childIndex = childIndex
            self.type = type
            self.variable = variable
        }

        private enum CodingKeys: String, CodingKey {
            case childIndex
            case type
            case variable
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            childIndex = try container.decodeFlexibleIntIfPresent(forKey: .childIndex) ?? 0
            type = try container.decodeIfPresent(String.self, forKey: .type)
            variable = try container.decodeIfPresent(String.self, forKey: .variable)
        }
    }

    public let index: Int
    public let kind: String?
    public let displayName: String
    public let childLinks: [ChildLink]
    public let shortDescription: String?
    public let metadata: [String: SpannerJSONValue]

    public init(
        index: Int,
        kind: String? = nil,
        displayName: String,
        childLinks: [ChildLink] = [],
        shortDescription: String? = nil,
        metadata: [String: SpannerJSONValue] = [:]
    ) {
        self.index = index
        self.kind = kind
        self.displayName = displayName
        self.childLinks = childLinks
        self.shortDescription = shortDescription
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case kind
        case displayName
        case childLinks
        case shortRepresentation
        case metadata
    }

    private enum ShortRepresentationKeys: String, CodingKey {
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeFlexibleIntIfPresent(forKey: .index) ?? 0
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        childLinks = try container.decodeArrayIfPresent(ChildLink.self, forKey: .childLinks)
        metadata = try container.decodeIfPresent([String: SpannerJSONValue].self, forKey: .metadata) ?? [:]
        shortDescription = try Self.decodeShortDescription(container)
    }

    private static func decodeShortDescription(_ container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.shortRepresentation),
              try !container.decodeNil(forKey: .shortRepresentation)
        else {
            return nil
        }
        let representation = try container.nestedContainer(
            keyedBy: ShortRepresentationKeys.self,
            forKey: .shortRepresentation
        )
        return try representation.decodeIfPresent(String.self, forKey: .description)
    }
}

public struct SpannerQueryPlan: Decodable, Sendable, Equatable {
    public let nodes: [SpannerPlanNode]

    public init(nodes: [SpannerPlanNode]) {
        self.nodes = nodes
    }

    private enum CodingKeys: String, CodingKey {
        case planNodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decodeArrayIfPresent(SpannerPlanNode.self, forKey: .planNodes)
    }
}

public struct SpannerResultSetStats: Decodable, Sendable, Equatable {
    public let rowCountExact: Int64?
    public let rowCountLowerBound: Int64?
    public let queryPlan: SpannerQueryPlan?

    public init(rowCountExact: Int64? = nil, rowCountLowerBound: Int64? = nil, queryPlan: SpannerQueryPlan? = nil) {
        self.rowCountExact = rowCountExact
        self.rowCountLowerBound = rowCountLowerBound
        self.queryPlan = queryPlan
    }

    private enum CodingKeys: String, CodingKey {
        case rowCountExact
        case rowCountLowerBound
        case queryPlan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowCountExact = try container.decodeFlexibleInt64IfPresent(forKey: .rowCountExact)
        rowCountLowerBound = try container.decodeFlexibleInt64IfPresent(forKey: .rowCountLowerBound)
        queryPlan = try container.decodeIfPresent(SpannerQueryPlan.self, forKey: .queryPlan)
    }
}

public struct SpannerResultSet: Decodable, Sendable, Equatable {
    public let metadata: SpannerResultSetMetadata?
    public let rows: [[SpannerJSONValue]]
    public let stats: SpannerResultSetStats?

    public init(metadata: SpannerResultSetMetadata?, rows: [[SpannerJSONValue]], stats: SpannerResultSetStats?) {
        self.metadata = metadata
        self.rows = rows
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case rows
        case stats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(SpannerResultSetMetadata.self, forKey: .metadata)
        rows = try container.decodeArrayIfPresent([SpannerJSONValue].self, forKey: .rows)
        stats = try container.decodeIfPresent(SpannerResultSetStats.self, forKey: .stats)
    }
}

public struct SpannerPartialResultSet: Decodable, Sendable, Equatable {
    public let metadata: SpannerResultSetMetadata?
    public let values: [SpannerJSONValue]
    public let chunkedValue: Bool
    public let resumeToken: String?
    public let stats: SpannerResultSetStats?

    public init(
        metadata: SpannerResultSetMetadata? = nil,
        values: [SpannerJSONValue],
        chunkedValue: Bool = false,
        resumeToken: String? = nil,
        stats: SpannerResultSetStats? = nil
    ) {
        self.metadata = metadata
        self.values = values
        self.chunkedValue = chunkedValue
        self.resumeToken = resumeToken
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case values
        case chunkedValue
        case resumeToken
        case stats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(SpannerResultSetMetadata.self, forKey: .metadata)
        values = try container.decodeArrayIfPresent(SpannerJSONValue.self, forKey: .values)
        chunkedValue = try container.decodeIfPresent(Bool.self, forKey: .chunkedValue) ?? false
        resumeToken = try container.decodeIfPresent(String.self, forKey: .resumeToken)
        stats = try container.decodeIfPresent(SpannerResultSetStats.self, forKey: .stats)
    }
}
