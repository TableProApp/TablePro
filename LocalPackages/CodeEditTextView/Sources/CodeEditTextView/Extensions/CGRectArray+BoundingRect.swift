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
        guard !self.isEmpty else { return .zero }
        let minX = self.min(by: { $0.origin.x < $1.origin.x })?.origin.x ?? 0
        let minY = self.min(by: { $0.origin.y < $1.origin.y })?.origin.y ?? 0
        let max = self.max(by: { $0.maxY < $1.maxY }) ?? .zero
        let origin = CGPoint(x: minX, y: minY)
        let size = CGSize(width: max.maxX - minX, height: max.maxY - minY)
        return CGRect(origin: origin, size: size)
    }
}
