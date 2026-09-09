//
//  DiagramZoom.swift
//  TablePro
//
//  Zoom bounds shared by the ER diagram and the EXPLAIN plan diagram.
//

import CoreGraphics

enum DiagramZoom {
    /// The ladder every zoom button step lands on. An absolute step cannot serve both ends of
    /// this range: 0.25 added to 3.0 is imperceptible while 0.25 subtracted from 0.41 is the
    /// floor, so one Zoom Out from a fitted large schema used to skip every level in between.
    static let ladder: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1.0, 1.5, 2.0, 3.0]

    /// Low enough that Fit to Window can still fit a schema too large for the ladder's floor.
    static var minimum: CGFloat { ladder[0] }
    static var maximum: CGFloat { ladder[ladder.count - 1] }

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

    /// A hair of tolerance keeps a magnification that landed on a rung by floating-point
    /// arithmetic from stepping onto itself.
    private static let rungTolerance: CGFloat = 0.001

    static func stepUp(from value: CGFloat) -> CGFloat {
        let current = clamped(value)
        return ladder.first { $0 > current + rungTolerance } ?? maximum
    }

    static func stepDown(from value: CGFloat) -> CGFloat {
        let current = clamped(value)
        return ladder.last { $0 < current - rungTolerance } ?? minimum
    }

    static func canStepUp(from value: CGFloat) -> Bool {
        clamped(value) < maximum - rungTolerance
    }

    static func canStepDown(from value: CGFloat) -> Bool {
        clamped(value) > minimum + rungTolerance
    }
}
