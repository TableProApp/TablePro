import Foundation

public struct MCPResult: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case complete
        case inputRequired = "input_required"
    }

    public let kind: Kind
    public let payload: [String: JsonValue]
    public let cacheHint: MCPCacheHint?
    public var meta: MCPResultMeta

    public init(
        kind: Kind = .complete,
        payload: [String: JsonValue] = [:],
        cacheHint: MCPCacheHint? = nil,
        meta: MCPResultMeta = MCPResultMeta()
    ) {
        self.kind = kind
        self.payload = payload
        self.cacheHint = cacheHint
        self.meta = meta
    }

    public static func complete(
        _ payload: [String: JsonValue],
        cacheHint: MCPCacheHint? = nil
    ) -> MCPResult {
        MCPResult(kind: .complete, payload: payload, cacheHint: cacheHint)
    }

    public static let empty = MCPResult(kind: .complete, payload: [:])

    public func asJsonValue(era: MCPEra, serverInfo: MCPImplementation?) -> JsonValue {
        var fields = payload
        var resultMeta = meta
        if era == .modern {
            fields["resultType"] = .string(kind.rawValue)
            if resultMeta.serverInfo == nil {
                resultMeta.serverInfo = serverInfo
            }
            cacheHint?.apply(to: &fields)
        }
        if let metaValue = resultMeta.asJsonValue(era: era) {
            fields["_meta"] = metaValue
        }
        return .object(fields)
    }
}
