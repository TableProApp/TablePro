//
//  SQLFoldRegion.swift
//  TablePro
//

import Foundation

/// A span of SQL that can be collapsed to a single line.
struct SQLFoldRegion: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case statement
        case parenGroup
        case keywordBlock
        case blockComment
        case quotedBody
    }

    let kind: Kind
    let depth: Int
    let range: Range<Int>
    let startLine: Int
    let endLine: Int
}

/// Every foldable region in a document, indexed by the line its events land on.
struct SQLFoldStructure: Sendable, Equatable {
    static let empty = SQLFoldStructure(startsByLine: [:], endsByLine: [:])

    let startsByLine: [Int: [SQLFoldRegion]]
    let endsByLine: [Int: [SQLFoldRegion]]

    var regions: [SQLFoldRegion] {
        startsByLine.values.flatMap { $0 }.sorted {
            $0.range.lowerBound == $1.range.lowerBound
                ? $0.depth < $1.depth
                : $0.range.lowerBound < $1.range.lowerBound
        }
    }
}
