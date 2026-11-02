import Foundation

public enum StatementTier: Sendable, Equatable {
    case safe
    case write
    case destructive
}

public struct StatementClassification: Sendable, Equatable {
    public let tier: StatementTier
    public let reachesFilesystemOrExecutesCode: Bool

    public init(tier: StatementTier, reachesFilesystemOrExecutesCode: Bool) {
        self.tier = tier
        self.reachesFilesystemOrExecutesCode = reachesFilesystemOrExecutesCode
    }

    public static let safe = StatementClassification(tier: .safe, reachesFilesystemOrExecutesCode: false)

    public static let write = StatementClassification(tier: .write, reachesFilesystemOrExecutesCode: false)

    public static let destructive = StatementClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)

    /// What a text no reading can lex is answered with.
    public static let mostSevere = StatementClassification(tier: .destructive, reachesFilesystemOrExecutesCode: true)

    public func escalated(to other: StatementTier) -> StatementClassification {
        StatementClassification(
            tier: Self.worse(tier, other),
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode
        )
    }

    public func markingUnsafeSurface() -> StatementClassification {
        StatementClassification(tier: Self.worse(tier, .write), reachesFilesystemOrExecutesCode: true)
    }

    public func escalated(with other: StatementClassification) -> StatementClassification {
        StatementClassification(
            tier: Self.worse(tier, other.tier),
            reachesFilesystemOrExecutesCode: reachesFilesystemOrExecutesCode || other.reachesFilesystemOrExecutesCode
        )
    }

    public static func worse(_ lhs: StatementTier, _ rhs: StatementTier) -> StatementTier {
        if lhs == .destructive || rhs == .destructive { return .destructive }
        if lhs == .write || rhs == .write { return .write }
        return .safe
    }
}
