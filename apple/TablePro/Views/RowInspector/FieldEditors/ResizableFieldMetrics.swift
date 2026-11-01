//
//  ResizableFieldMetrics.swift
//  TablePro
//

import Foundation
import SwiftUI

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

    /// The base is clamped before the drag is added. A field's height is shared by editors with
    /// different floors (a geometry map and its text pane, or a column whose values switch between
    /// JSON and text), and an unclamped base below the floor left the handle dead until the drag
    /// had covered the difference.
    static func resolve(base: Double, delta: Double, range: ClosedRange<Double>) -> Double {
        clamp(clamp(base, to: range) + delta, to: range)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// A drag sizes its own field only. Writing the per-kind default instead resized every field of
    /// that kind at once; the default is where a field starts until it is dragged.
    static func height(resized: Binding<Double?>, starting: Double) -> Binding<Double> {
        Binding(
            get: { resized.wrappedValue ?? starting },
            set: { resized.wrappedValue = $0 }
        )
    }
}
