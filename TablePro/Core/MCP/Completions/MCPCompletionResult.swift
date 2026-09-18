import Foundation

public struct MCPCompletionResult: Sendable, Equatable {
    public static let maximumValues = 100

    public let values: [String]
    public let total: Int
    public let hasMore: Bool

    public init(values: [String], total: Int? = nil) {
        let capped = Array(values.prefix(Self.maximumValues))
        let resolvedTotal = max(total ?? values.count, capped.count)
        self.values = capped
        self.total = resolvedTotal
        self.hasMore = resolvedTotal > capped.count
    }

    public static let empty = MCPCompletionResult(values: [])

    public var asJsonValue: JsonValue {
        .object([
            "values": .array(values.map { .string($0) }),
            "total": .int(total),
            "hasMore": .bool(hasMore)
        ])
    }
}

public extension MCPCompletionResult {
    static func matching(
        _ candidates: [String],
        prefix: String,
        preservingOrder: Bool = false
    ) -> MCPCompletionResult {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unique = deduplicated(candidates)
        guard !needle.isEmpty else {
            return MCPCompletionResult(values: ordered(unique, preservingOrder: preservingOrder))
        }

        var prefixed: [String] = []
        var contained: [String] = []
        for candidate in unique {
            let folded = candidate.lowercased()
            if folded.hasPrefix(needle) {
                prefixed.append(candidate)
            } else if folded.contains(needle) {
                contained.append(candidate)
            }
        }

        let ranked = ordered(prefixed, preservingOrder: preservingOrder)
            + ordered(contained, preservingOrder: preservingOrder)
        return MCPCompletionResult(values: ranked)
    }

    private static func ordered(_ candidates: [String], preservingOrder: Bool) -> [String] {
        guard !preservingOrder else { return candidates }
        return candidates.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func deduplicated(_ candidates: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            guard seen.insert(candidate).inserted else { continue }
            unique.append(candidate)
        }
        return unique
    }
}
