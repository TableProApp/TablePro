//
//  FoldRange.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/26/25.
//

/// Represents a single fold region with stable identifier and collapse state
struct FoldRange: Sendable, Equatable {
    typealias FoldIdentifier = UInt32

    let id: FoldIdentifier
    let depth: Int
    let range: Range<Int>
    var isCollapsed: Bool

    func isHoveringEqual(_ other: FoldRange) -> Bool {
        depth == other.depth && range.contains(other.range)
    }
}
