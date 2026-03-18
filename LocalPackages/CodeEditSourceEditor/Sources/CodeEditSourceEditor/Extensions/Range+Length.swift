//
//  Range+Length.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/25/24.
//

import Foundation

extension Range where Bound == Int {
    var length: Bound { upperBound - lowerBound }

    /// The final index covered by this range. If the range has 0 length (upper bound = lower bound) it returns the
    /// single value represented by the range (lower bound)
    var lastIndex: Bound { upperBound == lowerBound ? upperBound : upperBound - 1 }

    init(lowerBound: Int, length: Int) {
        self = lowerBound..<(lowerBound + length)
    }
}
