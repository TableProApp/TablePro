//
//  InspectorColumnTargets.swift
//  TablePro
//

import Foundation

enum InspectorColumnTargets {
    static func deleteMenuSelection(clicked: Int, fullySelected: IndexSet) -> [Int] {
        guard fullySelected.contains(clicked), fullySelected.count > 1 else { return [clicked] }
        return fullySelected.sorted()
    }

    static func deleteTargets(explicit: [Int]?, fullySelected: IndexSet, columnCount: Int) -> [Int] {
        let candidates = explicit ?? Array(fullySelected)
        return candidates.filter { $0 >= 0 && $0 < columnCount }.sorted()
    }

    static func insertAnchor(clicked: Int?, fullySelected: IndexSet, columnCount: Int, toRight: Bool) -> Int? {
        guard columnCount > 0 else { return nil }
        if let clicked, clicked >= 0, clicked < columnCount {
            return clicked
        }
        if let bound = toRight ? fullySelected.max() : fullySelected.min(), bound >= 0, bound < columnCount {
            return bound
        }
        return toRight ? columnCount - 1 : 0
    }
}
