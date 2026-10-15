import Foundation

public struct SQLFoldRegion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case statement
        case parenGroup
        case keywordBlock
        case blockComment
        case quotedBody
    }

    public let kind: Kind
    public let depth: Int
    public let range: Range<Int>
    public let startLine: Int
    public let endLine: Int
}

/// Indexed by the line each region's start or end lands on.
public struct SQLFoldStructure: Sendable, Equatable {
    public static let empty = SQLFoldStructure(startsByLine: [:], endsByLine: [:])

    public let startsByLine: [Int: [SQLFoldRegion]]
    public let endsByLine: [Int: [SQLFoldRegion]]

    public var regions: [SQLFoldRegion] {
        startsByLine.values.flatMap { $0 }.sorted {
            $0.range.lowerBound == $1.range.lowerBound
                ? $0.depth < $1.depth
                : $0.range.lowerBound < $1.range.lowerBound
        }
    }
}
