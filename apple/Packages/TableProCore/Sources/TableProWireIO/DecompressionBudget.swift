public struct DecompressionBudget: Sendable, Equatable {
    public let limit: Int
    public let ratioLimit: Int
    public let grace: Int
    public private(set) var produced = 0
    public private(set) var consumed = 0

    public init(limit: Int = .max, ratioLimit: Int, grace: Int) {
        self.limit = limit
        self.ratioLimit = ratioLimit
        self.grace = grace
    }

    // Past 64 MiB of output, refuse more than 250 bytes out per byte in: a deflate stream of one
    // repeated byte packs about 1,000 to 1, while real exports stay well under the limit.
    public static let standard = DecompressionBudget(ratioLimit: 250, grace: 64 << 20)

    public var remaining: Int { max(limit - produced, 0) }

    public mutating func record(produced newlyProduced: Int, consumed newlyConsumed: Int) throws(WireIOError) {
        produced = Self.saturatingSum(produced, newlyProduced)
        consumed = Self.saturatingSum(consumed, newlyConsumed)
        guard produced <= limit else {
            throw .expansionExceeded(produced: produced, consumed: consumed)
        }
        guard produced > grace else { return }
        guard produced / max(consumed, 1) <= ratioLimit else {
            throw .expansionExceeded(produced: produced, consumed: consumed)
        }
    }

    private static func saturatingSum(_ total: Int, _ addition: Int) -> Int {
        let (sum, overflow) = total.addingReportingOverflow(max(addition, 0))
        return overflow ? .max : sum
    }
}
