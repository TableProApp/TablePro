//
//  DiagramZoom.swift
//  TablePro
//
//  Zoom bounds shared by the ER diagram and the EXPLAIN plan diagram.
//

import CoreGraphics

enum DiagramZoom {
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 3.0
    static let step: CGFloat = 0.25

    static func clamped(_ value: CGFloat) -> CGFloat {
        if value.isNaN { return 1.0 }
        if value == .infinity { return maximum }
        if value == -.infinity { return minimum }
        return min(maximum, max(minimum, value))
    }

    static func scaled(from startingMagnification: CGFloat, by gestureMagnification: CGFloat) -> CGFloat {
        let startingMagnification = clamped(startingMagnification)
        guard gestureMagnification.isFinite, gestureMagnification > 0 else {
            return startingMagnification
        }
        return clamped(startingMagnification * gestureMagnification)
    }
}
