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

    // MapKit hides its logo and legal link on a map under 100pt tall, and the HIG asks for both.
    static let geometryHeightRange: ClosedRange<Double> = 100...600
    static let defaultGeometryHeight: Double = 160

    // Short enough that the fields around an expanded one stay on screen, unlike a full-pane takeover.
    static let expandedHeight: Double = 320

    // The base is clamped first: a geometry map and its text pane share one height under different floors.
    static func resolve(base: Double, delta: Double, range: ClosedRange<Double>) -> Double {
        clamp(clamp(base, to: range) + delta, to: range)
    }

    // A drag that ends where it began stores nothing, so the field keeps following its default.
    static func committedHeight(base: Double, delta: Double, range: ClosedRange<Double>) -> Double? {
        delta == 0 ? nil : resolve(base: base, delta: delta, range: range)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
