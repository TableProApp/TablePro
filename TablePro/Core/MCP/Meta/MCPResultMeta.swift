import Foundation

public struct MCPResultMeta: Sendable, Equatable {
    public var serverInfo: MCPImplementation?
    public var subscriptionId: JsonRpcId?
    public var passthrough: [String: JsonValue]

    public init(
        serverInfo: MCPImplementation? = nil,
        subscriptionId: JsonRpcId? = nil,
        passthrough: [String: JsonValue] = [:]
    ) {
        self.serverInfo = serverInfo
        self.subscriptionId = subscriptionId
        self.passthrough = passthrough
    }

    public var isEmpty: Bool {
        serverInfo == nil && subscriptionId == nil && passthrough.isEmpty
    }

    public func asJsonValue(era: MCPEra) -> JsonValue? {
        var fields = passthrough
        if era == .modern, let serverInfo {
            fields[MCPMetaKeys.serverInfo] = serverInfo.asJsonValue
        }
        if let subscriptionId {
            fields[MCPMetaKeys.subscriptionId] = subscriptionId.asJsonValue
        }
        guard !fields.isEmpty else { return nil }
        return .object(fields)
    }
}
