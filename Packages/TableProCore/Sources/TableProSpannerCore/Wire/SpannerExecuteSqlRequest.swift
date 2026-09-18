import Foundation

public enum SpannerTransactionSelector: Sendable, Equatable {
    case singleUseStrongReadOnly
    case beginReadWrite
    case id(String)
}

public enum SpannerQueryMode: String, Sendable {
    case normal = "NORMAL"
    case plan = "PLAN"
}

public struct SpannerExecuteSqlRequest: Sendable, Equatable, Encodable {
    public var sql: String
    public var transaction: SpannerTransactionSelector
    public var params: [String: SpannerJSONValue]
    public var paramTypes: [String: SpannerType]
    public var queryMode: SpannerQueryMode
    public var seqno: Int64?

    public init(
        sql: String,
        transaction: SpannerTransactionSelector,
        params: [String: SpannerJSONValue] = [:],
        paramTypes: [String: SpannerType] = [:],
        queryMode: SpannerQueryMode = .normal,
        seqno: Int64? = nil
    ) {
        self.sql = sql
        self.transaction = transaction
        self.params = params
        self.paramTypes = paramTypes
        self.queryMode = queryMode
        self.seqno = seqno
    }

    var isReplaySafe: Bool {
        seqno != nil || transaction == .singleUseStrongReadOnly || queryMode == .plan
    }

    private enum CodingKeys: String, CodingKey {
        case sql
        case transaction
        case params
        case paramTypes
        case queryMode
        case seqno
    }

    private enum SelectorKeys: String, CodingKey {
        case singleUse
        case begin
        case id
    }

    private enum ModeKeys: String, CodingKey {
        case readOnly
        case readWrite
    }

    private enum ReadOnlyKeys: String, CodingKey {
        case strong
    }

    private struct EmptyObject: Encodable {}

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sql, forKey: .sql)
        try encodeTransaction(into: container.nestedContainer(keyedBy: SelectorKeys.self, forKey: .transaction))
        if !params.isEmpty {
            try container.encode(params, forKey: .params)
        }
        if !paramTypes.isEmpty {
            try container.encode(paramTypes, forKey: .paramTypes)
        }
        try container.encode(queryMode.rawValue, forKey: .queryMode)
        if let seqno {
            try container.encode(String(seqno), forKey: .seqno)
        }
    }

    private func encodeTransaction(into selector: KeyedEncodingContainer<SelectorKeys>) throws {
        var selector = selector
        switch transaction {
        case .singleUseStrongReadOnly:
            var mode = selector.nestedContainer(keyedBy: ModeKeys.self, forKey: .singleUse)
            var readOnly = mode.nestedContainer(keyedBy: ReadOnlyKeys.self, forKey: .readOnly)
            try readOnly.encode(true, forKey: .strong)
        case .beginReadWrite:
            var mode = selector.nestedContainer(keyedBy: ModeKeys.self, forKey: .begin)
            try mode.encode(EmptyObject(), forKey: .readWrite)
        case .id(let identifier):
            try selector.encode(identifier, forKey: .id)
        }
    }
}
