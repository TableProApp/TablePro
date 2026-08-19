//
//  ResultChartSelection.swift
//  TablePro
//

import Foundation

struct ResultChartSelection: Equatable {
    let x: ResultChartProjection.XValue
    let rawX: String
    let points: [ResultChartProjection.Point]

    static func categorical(
        in projection: ResultChartProjection,
        selectedX: String?
    ) -> ResultChartSelection? {
        guard let selectedX else { return nil }
        let points = projection.points.filter { point in
            point.x == .category(selectedX)
        }
        guard let first = points.first else { return nil }
        return ResultChartSelection(x: first.x, rawX: first.rawX, points: points)
    }

    static func numeric(
        in projection: ResultChartProjection,
        selectedX: Decimal?
    ) -> ResultChartSelection? {
        guard let selectedX else { return nil }
        let target = NSDecimalNumber(decimal: selectedX).doubleValue
        guard target.isFinite else { return nil }

        let nearest = projection.points.compactMap { point -> (ResultChartProjection.Point, Double)? in
            guard case .number(let value) = point.x else { return nil }
            let primitive = NSDecimalNumber(decimal: value).doubleValue
            guard primitive.isFinite else { return nil }
            return (point, abs(primitive - target))
        }
        .min { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.sourceIndex < rhs.0.sourceIndex
            }
            return lhs.1 < rhs.1
        }?
        .0

        guard let nearest else { return nil }
        let points = projection.points.filter { $0.x == nearest.x }
        return ResultChartSelection(x: nearest.x, rawX: nearest.rawX, points: points)
    }
}
