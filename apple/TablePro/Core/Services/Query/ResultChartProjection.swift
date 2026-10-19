//
//  ResultChartProjection.swift
//  TablePro
//

import Foundation

struct ResultChartProjection: Equatable, Sendable {
    enum XValue: Hashable, Sendable {
        case category(String)
        case number(Double)
        case date(Date)
    }

    /// A series or facet cell. It stays apart from its label, so a NULL and a literal "No value" are
    /// two groups even though both would read the same.
    enum GroupValue: Hashable, Sendable {
        case value(String)
        case missing

        /// The data grid's words for the two cells that have no text of their own.
        var baseLabel: String {
            switch self {
            case .value(let raw) where raw.isEmpty: return String(localized: "Empty")
            case .value(let raw): return raw
            case .missing: return String(localized: "No value")
            }
        }

        /// The order that does not depend on row order. Series colours and duplicate-label numbers
        /// follow it, so a re-sort or a page turn that brings another value first changes neither.
        static func areInIncreasingOrder(_ lhs: GroupValue, _ rhs: GroupValue) -> Bool {
            switch (lhs, rhs) {
            case (.value(let left), .value(let right)):
                switch left.localizedStandardCompare(right) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return left < right
                }
            case (.value, .missing):
                return true
            case (.missing, _):
                return false
            }
        }
    }

    /// What the legend, the panel title, the callout and VoiceOver show for a group, and the value
    /// the chart plots it under. Labels are unique within a projection: two groups that would read
    /// the same are numbered the way duplicate column names are.
    struct Group: Hashable, Sendable {
        let value: GroupValue
        let label: String

        init(_ value: GroupValue, label: String? = nil) {
            self.value = value
            self.label = label ?? value.baseLabel
        }

        /// Labels distinct values, in the order given, numbering duplicates in the row-order-free
        /// order so "No value (1)" names the same group after a re-sort.
        static func labeled(_ values: [GroupValue]) -> [Group] {
            let sorted = values.sorted(by: GroupValue.areInIncreasingOrder)
            let labels = Dictionary(
                uniqueKeysWithValues: zip(sorted, ResultChartLabels.unique(sorted.map(\.baseLabel)))
            )
            return values.map { Group($0, label: labels[$0]) }
        }
    }

    /// A bound the projection ran into. The points already gathered are kept and drawn: a result one
    /// row over a cap is a chart with a note, not an error card.
    enum Limit: Equatable, Sendable {
        case points(limit: Int)
        case series(limit: Int)
        case facets(limit: Int)
        case inspectedRows(limit: Int)
    }

    struct Point: Identifiable, Equatable, Sendable {
        let sourceIndex: Int
        let x: XValue
        let y: Double
        let rawX: String
        let rawY: String
        let series: Group?
        let facet: Group?
        let barGroup: Int
        let lineGroup: Int

        init(
            sourceIndex: Int,
            x: XValue,
            y: Double,
            rawX: String,
            rawY: String,
            series: Group?,
            facet: Group? = nil,
            barGroup: Int,
            lineGroup: Int
        ) {
            self.sourceIndex = sourceIndex
            self.x = x
            self.y = y
            self.rawX = rawX
            self.rawY = rawY
            self.series = series
            self.facet = facet
            self.barGroup = barGroup
            self.lineGroup = lineGroup
        }

        var id: Int { sourceIndex }

        /// A category plots under its label, which names an empty string; numbers and dates read as
        /// the database wrote them.
        var xLabel: String {
            if case .category(let label) = x { return label }
            return rawX
        }
    }

    /// One chart of the grid. An unfaceted projection is a single panel with no facet.
    struct Panel: Identifiable, Equatable, Sendable {
        let facet: Group?
        let points: [Point]

        var id: String { facet?.label ?? "" }
    }

    /// The extent of every panel's points, so panels drawn as separate charts share their axes.
    struct Domain: Equatable, Sendable {
        let categories: [String]
        let numbers: ClosedRange<Double>?
        let dates: ClosedRange<Date>?
        let y: ClosedRange<Double>?

        init(points: [Point]) {
            var categories: [String] = []
            var seenCategories: Set<String> = []
            var numbers: ClosedRange<Double>?
            var dates: ClosedRange<Date>?
            var y: ClosedRange<Double>?

            for point in points {
                switch point.x {
                case .category(let label):
                    if seenCategories.insert(label).inserted { categories.append(label) }
                case .number(let value):
                    numbers = Self.extend(numbers, with: value)
                case .date(let value):
                    dates = Self.extend(dates, with: value)
                }
                y = Self.extend(y, with: point.y)
            }

            self.categories = categories
            self.numbers = numbers
            self.dates = dates
            self.y = y
        }

        private static func extend<Bound: Comparable>(_ range: ClosedRange<Bound>?, with value: Bound) -> ClosedRange<Bound> {
            guard let range else { return value...value }
            return min(range.lowerBound, value)...max(range.upperBound, value)
        }
    }

    let points: [Point]
    let xAxisKind: ResultChartColumn.AxisKind
    let limits: [Limit]
    let loadedRowCount: Int
    let skippedRowCount: Int
    let xAxisLabel: String
    let yAxisLabel: String
    let seriesLabel: String?
    let facetLabel: String?
    /// False for row numbers: each panel numbers only its own rows, so a shared axis would squeeze
    /// every panel into its slice of the whole result.
    let sharesXAxis: Bool

    /// Every series, in the order the rows first name them, which is the legend's order.
    let series: [Group]
    let panels: [Panel]
    let domain: Domain

    init(
        points: [Point],
        xAxisKind: ResultChartColumn.AxisKind,
        limits: [Limit],
        loadedRowCount: Int,
        skippedRowCount: Int,
        xAxisLabel: String,
        yAxisLabel: String,
        seriesLabel: String?,
        facetLabel: String? = nil,
        sharesXAxis: Bool = true
    ) {
        self.points = points
        self.xAxisKind = xAxisKind
        self.limits = limits
        self.loadedRowCount = loadedRowCount
        self.skippedRowCount = skippedRowCount
        self.xAxisLabel = xAxisLabel
        self.yAxisLabel = yAxisLabel
        self.seriesLabel = seriesLabel
        self.facetLabel = facetLabel
        self.sharesXAxis = sharesXAxis
        series = Self.orderedGroups(points.compactMap(\.series))
        panels = Self.panels(points: points, isFaceted: facetLabel != nil)
        domain = Domain(points: points)
    }

    var isFaceted: Bool { facetLabel != nil }

    /// First appearance, so the query's ORDER BY orders the legend and the panels, and the caps
    /// keep the first values a reader sees.
    private static func orderedGroups(_ groups: [Group]) -> [Group] {
        var seen: Set<GroupValue> = []
        return groups.filter { seen.insert($0.value).inserted }
    }

    private static func panels(points: [Point], isFaceted: Bool) -> [Panel] {
        guard isFaceted else { return [Panel(facet: nil, points: points)] }
        var grouped: [GroupValue: [Point]] = [:]
        for point in points {
            guard let facet = point.facet else { continue }
            grouped[facet.value, default: []].append(point)
        }
        return orderedGroups(points.compactMap(\.facet)).map { facet in
            Panel(facet: facet, points: grouped[facet.value] ?? [])
        }
    }
}
