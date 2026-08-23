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

    static func resolve(base: Double, delta: Double, range: ClosedRange<Double>) -> Double {
        min(max(base + delta, range.lowerBound), range.upperBound)
    }
}
