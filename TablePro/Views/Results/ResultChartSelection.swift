//
//  ResultChartSelection.swift
//  TablePro
//

import Foundation

struct ResultChartSelection: Equatable {
    let x: ResultChartProjection.XValue
    let rawX: String
    let points: [ResultChartProjection.Point]
}

/// Hover updates arrive continuously while the pointer moves, so the grouping is done once per
/// projection and every frame after that is a dictionary read or a binary search.
struct ResultChartSelectionIndex {
    private let categories: [String: ResultChartSelection]
    private let numbers: [(value: Double, selection: ResultChartSelection)]
    private let dates: [(value: Date, selection: ResultChartSelection)]

    init(projection: ResultChartProjection) {
        var order: [ResultChartProjection.XValue] = []
        var grouped: [ResultChartProjection.XValue: [ResultChartProjection.Point]] = [:]
        var raw: [ResultChartProjection.XValue: String] = [:]

        for point in projection.points {
            if grouped[point.x] == nil {
                order.append(point.x)
                raw[point.x] = point.rawX
            }
            grouped[point.x, default: []].append(point)
        }

        var categories: [String: ResultChartSelection] = [:]
        var numbers: [(value: Double, selection: ResultChartSelection)] = []
        var dates: [(value: Date, selection: ResultChartSelection)] = []

        for value in order {
            let selection = ResultChartSelection(
                x: value,
                rawX: raw[value] ?? "",
                points: grouped[value] ?? []
            )
            switch value {
            case .category(let key): categories[key] = selection
            case .number(let key): numbers.append((key, selection))
            case .date(let key): dates.append((key, selection))
            }
        }

        self.categories = categories
        self.numbers = numbers.sorted { $0.value < $1.value }
        self.dates = dates.sorted { $0.value < $1.value }
    }

    func selection(forCategory category: String?) -> ResultChartSelection? {
        guard let category else { return nil }
        return categories[category]
    }

    /// A continuous axis reports where the pointer is, not a value that exists, so the nearest
    /// plotted value wins.
    func selection(nearestNumber target: Double?) -> ResultChartSelection? {
        guard let target, target.isFinite else { return nil }
        return Self.nearest(to: target, in: numbers) { abs($0 - $1) }
    }

    func selection(nearestDate target: Date?) -> ResultChartSelection? {
        guard let target else { return nil }
        return Self.nearest(to: target, in: dates) { abs($0.timeIntervalSince($1)) }
    }

    private static func nearest<Value: Comparable>(
        to target: Value,
        in entries: [(value: Value, selection: ResultChartSelection)],
        distance: (Value, Value) -> Double
    ) -> ResultChartSelection? {
        guard !entries.isEmpty else { return nil }

        var low = entries.startIndex
        var high = entries.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].value < target {
                low = middle + 1
            } else {
                high = middle
            }
        }

        guard low > entries.startIndex else { return entries[low].selection }
        guard low < entries.endIndex else { return entries[low - 1].selection }
        let before = entries[low - 1]
        let after = entries[low]
        return distance(after.value, target) < distance(before.value, target)
            ? after.selection
            : before.selection
    }
}
