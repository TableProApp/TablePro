import Foundation

public struct MCPProtocolVersion: RawRepresentable, Sendable, Hashable, Comparable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let v20260728 = MCPProtocolVersion("2026-07-28")
    public static let v20251125 = MCPProtocolVersion("2025-11-25")
    public static let v20250618 = MCPProtocolVersion("2025-06-18")

    public static let latest = v20260728

    public static let modern: Set<MCPProtocolVersion> = [.v20260728]

    public static let legacy: Set<MCPProtocolVersion> = [.v20251125, .v20250618]

    public static let supported: Set<MCPProtocolVersion> = modern.union(legacy)

    public static let advertisedOrder: [MCPProtocolVersion] = [.v20260728, .v20251125, .v20250618]

    public static var supportedRawValues: [String] {
        advertisedOrder.map(\.rawValue)
    }

    public var era: MCPEra {
        Self.modern.contains(self) ? .modern : .legacy
    }

    public var isSupported: Bool {
        Self.supported.contains(self)
    }

    public static func < (lhs: MCPProtocolVersion, rhs: MCPProtocolVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MCPEra: Sendable, Hashable {
    case modern
    case legacy
}
