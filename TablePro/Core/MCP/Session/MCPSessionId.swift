import Foundation

public struct MCPSessionId: Sendable, Hashable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> MCPSessionId {
        MCPSessionId(UUID().uuidString)
    }

    public var description: String {
        rawValue
    }
}
