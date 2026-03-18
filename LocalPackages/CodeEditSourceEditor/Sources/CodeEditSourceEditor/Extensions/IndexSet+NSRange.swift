//
//  IndexSet+NSRange.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/12/23.
//

import Foundation

extension NSRange {
    /// Convenience getter for safely creating a `Range<Int>` from an `NSRange`
    var intRange: Range<Int> {
        self.location..<NSMaxRange(self)
    }
}

/// Helpers for working with `NSRange`s and `IndexSet`s.
extension IndexSet {
    /// Initializes the  index set with a range of integers
    init(integersIn range: NSRange) {
        self.init(integersIn: range.intRange)
    }

    /// Remove all the integers in the `NSRange`
    mutating func remove(integersIn range: NSRange) {
        self.remove(integersIn: range.intRange)
    }

    /// Insert all the integers in the `NSRange`
    mutating func insert(integersIn range: NSRange) {
        self.insert(integersIn: range.intRange)
    }

    /// Returns true if self contains all of the integers in range.
    func contains(integersIn range: NSRange) -> Bool {
        return self.contains(integersIn: range.intRange)
    }
}
