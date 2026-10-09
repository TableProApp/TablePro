//
//  ResizableFieldMetrics.swift
//  TablePro
//

import Foundation

internal enum ResizableFieldMetrics {
    static let jsonHeightRange: ClosedRange<Double> = 80...600
    static let defaultJsonHeight: Double = 120

    static let textHeightRange: ClosedRange<Double> = 60...600
    static let defaultTextHeight: Double = 110

    /// MapKit hides its logo and legal link on a map under 100pt tall, and the HIG asks for both.
    static let geometryHeightRange: ClosedRange<Double> = 100...600
    static let defaultGeometryHeight: Double = 160

    /// What a field grows to when it is expanded in place. Tall enough to be worth the gesture and
    /// short enough that the fields around it are still on screen, which is the whole difference
    /// between this and the full-pane takeover it replaces.
    static let expandedHeight: Double = 320

    static func resolve(base: Double, delta: Double, range: ClosedRange<Double>) -> Double {
        min(max(base + delta, range.lowerBound), range.upperBound)
    }
}
