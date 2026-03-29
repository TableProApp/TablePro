//
//  GC+ApproximateEqual.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/16/24.
//

import Foundation

extension CGFloat {
    func approxEqual(_ other: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
        abs(self - other) <= tolerance
    }
}

extension CGPoint {
    func approxEqual(_ other: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
        return self.x.approxEqual(other.x, tolerance: tolerance)
        && self.y.approxEqual(other.y, tolerance: tolerance)
    }
}

extension CGRect {
    func approxEqual(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        return self.origin.approxEqual(other.origin, tolerance: tolerance)
        && self.width.approxEqual(other.width, tolerance: tolerance)
        && self.height.approxEqual(other.height, tolerance: tolerance)
    }
}
