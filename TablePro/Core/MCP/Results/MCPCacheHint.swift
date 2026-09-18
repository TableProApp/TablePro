import Foundation

public struct MCPCacheHint: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        case publicScope = "public"
        case privateScope = "private"
    }

    public let ttlMilliseconds: Int
    public let scope: Scope

    public init(ttlMilliseconds: Int, scope: Scope) {
        self.ttlMilliseconds = max(0, ttlMilliseconds)
        self.scope = scope
    }

    public static func publicFor(seconds: Int) -> MCPCacheHint {
        MCPCacheHint(ttlMilliseconds: seconds * 1_000, scope: .publicScope)
    }

    public static func privateFor(seconds: Int) -> MCPCacheHint {
        MCPCacheHint(ttlMilliseconds: seconds * 1_000, scope: .privateScope)
    }

    public static let uncacheable = MCPCacheHint(ttlMilliseconds: 0, scope: .privateScope)

    public func apply(to fields: inout [String: JsonValue]) {
        fields["ttlMs"] = .int(ttlMilliseconds)
        fields["cacheScope"] = .string(scope.rawValue)
    }
}
