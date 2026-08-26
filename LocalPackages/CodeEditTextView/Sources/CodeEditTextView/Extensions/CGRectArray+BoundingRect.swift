//
//  File.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/25.
//

import AppKit

extension Array where Element == CGRect {
    /// Returns a rect object that contains all of the rects in this array.
    /// Returns `.zero` if the array is empty.
    /// - Returns: The minimum rectangle that contains all rectangles in this array.
    func boundingRect() -> CGRect {
        guard let first = self.first else { return .zero }
        return self.dropFirst().reduce(first) { $0.union($1) }
    }
}
