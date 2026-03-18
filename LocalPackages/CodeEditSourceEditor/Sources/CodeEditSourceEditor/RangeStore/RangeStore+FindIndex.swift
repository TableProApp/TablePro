//
//  RangeStore+FindIndex.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/6/25.
//

extension RangeStore {
    /// Finds a Rope index, given a string offset.
    /// - Parameter offset: The offset to query for.
    /// - Returns: The index of the containing element in the rope.
    func findIndex(at offset: Int) -> (index: Index, remaining: Int) {
        _guts.find(at: offset, in: OffsetMetric(), preferEnd: false)
    }

    /// Finds the value stored at a given string offset.
    /// - Parameter offset: The offset to query for.
    /// - Returns: The element stored, if any.
    func findValue(at offset: Int) -> Element? {
        _guts[findIndex(at: offset).index].value
    }
}
