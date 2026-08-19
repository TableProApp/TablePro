//
//  ResultChartCanvas.swift
//  TablePro
//

import Charts
import SwiftUI

struct ResultChartCanvas: View {
    /// Solid first, then patterns that stay legible in monochrome and to a colour-blind reader,
    /// because colour alone does not distinguish a series.
    private static let seriesDashPatterns: [[CGFloat]] = [
        [], [6, 3], [2, 3], [8, 3, 2, 3], [1, 3], [10, 4],
    ]

    let projection: ResultChartProjection
    let chartType: ResultChartType

    private let selectionIndex: ResultChartSelectionIndex
    private let seriesNames: [String]

    @State private var selectedCategory: String?
    @State private var selectedNumber: Double?
    @State private var selectedDate: Date?

    init(projection: ResultChartProjection, chartType: ResultChartType) {
        self.projection = projection
        self.chartType = chartType
        selectionIndex = ResultChartSelectionIndex(projection: projection)
        seriesNames = Self.orderedSeriesNames(in: projection)
    }

    var body: some View {
        Group {
            switch projection.xAxisKind {
            case .category: categoricalChart
            case .number: numericChart
            case .date: dateChart
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.55))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.55))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 8))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.45),
                    in: .rect(cornerRadius: 8)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("result-chart")
    }

    private var categoricalChart: some View {
        let selection = selectionIndex.selection(forCategory: selectedCategory)
        return legend(Chart {
            ForEach(projection.points) { point in
                if case .category(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .category(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelection(value: $selectedCategory)
    }

    private var numericChart: some View {
        let selection = selectionIndex.selection(nearestNumber: selectedNumber)
        return legend(Chart {
            ForEach(projection.points) { point in
                if case .number(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .number(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelection(value: $selectedNumber)
    }

    private var dateChart: some View {
        let selection = selectionIndex.selection(nearestDate: selectedDate)
        return legend(Chart {
            ForEach(projection.points) { point in
                if case .date(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .date(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelection(value: $selectedDate)
    }

    /// The per-series stroke lives on the chart's line-style scale, not on the mark: a constant
    /// `lineStyle` applied after `lineStyle(by:)` replaces it, which leaves colour as the only thing
    /// telling two series apart.
    @ViewBuilder
    private func legend(_ chart: some View) -> some View {
        let styled = chart
            .chartLegend(projection.seriesLabel == nil ? .hidden : .visible)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        if seriesNames.isEmpty {
            styled
        } else {
            styled.chartLineStyleScale(range: seriesStrokeStyles)
        }
    }

    private var seriesStrokeStyles: [StrokeStyle] {
        seriesNames.indices.map { index in
            StrokeStyle(
                lineWidth: 2,
                lineCap: .round,
                lineJoin: .round,
                dash: Self.seriesDashPatterns[index % Self.seriesDashPatterns.count]
            )
        }
    }

    @ChartContentBuilder
    private func mark<X: Plottable>(for point: ResultChartProjection.Point, x: X) -> some ChartContent {
        let series = point.series?.displayName
        switch chartType {
        case .bar: barMark(for: point, x: x, series: series)
        case .line: lineMark(for: point, x: x, series: series)
        case .area: areaMark(for: point, x: x, series: series)
        case .scatter: scatterMark(for: point, x: x, series: series)
        }
    }

    /// The grouping dimension is a slot, so its value has to be discrete. Swift Charts reads an
    /// `Int` as a continuous offset, which drops a repeated category's second bar into the next
    /// category's band; the scale orders discrete slots by first appearance, so the ordinal's
    /// string keeps them in order.
    private func slot(_ point: ResultChartProjection.Point) -> PlottableValue<String> {
        .value(String(localized: "Row"), String(point.barGroup))
    }

    private func seriesValue(_ series: String) -> PlottableValue<String> {
        .value(projection.seriesLabel ?? String(localized: "Series"), series)
    }

    @ChartContentBuilder
    private func barMark<X: Plottable>(
        for point: ResultChartProjection.Point,
        x: X,
        series: String?
    ) -> some ChartContent {
        if let series {
            BarMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                stacking: .unstacked
            )
            .position(by: slot(point))
            .foregroundStyle(by: seriesValue(series))
            .accessibilityLabel(pointAccessibilityLabel(point, series: series))
            .accessibilityValue(pointAccessibilityValue(point))
            PointMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y)
            )
            .position(by: slot(point))
            .foregroundStyle(by: seriesValue(series))
            .symbol(by: seriesValue(series))
            .symbolSize(28)
            .accessibilityHidden(true)
        } else {
            BarMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                stacking: .unstacked
            )
            .position(by: slot(point))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(pointAccessibilityLabel(point, series: nil))
            .accessibilityValue(pointAccessibilityValue(point))
        }
    }

    @ChartContentBuilder
    private func lineMark<X: Plottable>(
        for point: ResultChartProjection.Point,
        x: X,
        series: String?
    ) -> some ChartContent {
        if let series {
            LineMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                series: .value(String(localized: "Line"), point.lineGroup)
            )
            .foregroundStyle(by: seriesValue(series))
            .lineStyle(by: seriesValue(series))
            .accessibilityLabel(pointAccessibilityLabel(point, series: series))
            .accessibilityValue(pointAccessibilityValue(point))
            PointMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y)
            )
            .foregroundStyle(by: seriesValue(series))
            .symbol(by: seriesValue(series))
            .symbolSize(42)
            .accessibilityHidden(true)
        } else {
            LineMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                series: .value(String(localized: "Line"), point.lineGroup)
            )
            .foregroundStyle(Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .accessibilityLabel(pointAccessibilityLabel(point, series: nil))
            .accessibilityValue(pointAccessibilityValue(point))
            PointMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y)
            )
            .foregroundStyle(Color.accentColor)
            .symbolSize(42)
            .accessibilityHidden(true)
        }
    }

    /// An area chart is a line chart with a fill under it, so the stroke, the points and the
    /// series break all come from `lineMark`; only the fill is different.
    @ChartContentBuilder
    private func areaMark<X: Plottable>(
        for point: ResultChartProjection.Point,
        x: X,
        series: String?
    ) -> some ChartContent {
        if let series {
            AreaMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                series: .value(String(localized: "Line"), point.lineGroup),
                stacking: .unstacked
            )
            .foregroundStyle(by: seriesValue(series))
            .opacity(0.18)
            .accessibilityHidden(true)
        } else {
            AreaMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y),
                series: .value(String(localized: "Line"), point.lineGroup),
                stacking: .unstacked
            )
            .foregroundStyle(Color.accentColor.opacity(0.18))
            .accessibilityHidden(true)
        }
        lineMark(for: point, x: x, series: series)
    }

    @ChartContentBuilder
    private func scatterMark<X: Plottable>(
        for point: ResultChartProjection.Point,
        x: X,
        series: String?
    ) -> some ChartContent {
        if let series {
            PointMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y)
            )
            .foregroundStyle(by: seriesValue(series))
            .symbol(by: seriesValue(series))
            .symbolSize(48)
            .accessibilityLabel(pointAccessibilityLabel(point, series: series))
            .accessibilityValue(pointAccessibilityValue(point))
        } else {
            PointMark(
                x: .value(projection.xAxisLabel, x),
                y: .value(projection.yAxisLabel, point.y)
            )
            .foregroundStyle(Color.accentColor)
            .symbolSize(48)
            .accessibilityLabel(pointAccessibilityLabel(point, series: nil))
            .accessibilityValue(pointAccessibilityValue(point))
        }
    }

    @ChartContentBuilder
    private func selectionMark<X: Plottable>(at x: X, selection: ResultChartSelection) -> some ChartContent {
        RuleMark(x: .value(projection.xAxisLabel, x))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .annotation(
                position: .top,
                alignment: .leading,
                spacing: 8,
                overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))
            ) {
                ResultChartSelectionCallout(
                    selection: selection,
                    xAxisLabel: projection.xAxisLabel,
                    yAxisLabel: projection.yAxisLabel,
                    seriesLabel: projection.seriesLabel
                )
            }
            .accessibilityHidden(true)
    }

    static func orderedSeriesNames(in projection: ResultChartProjection) -> [String] {
        var seen: Set<ResultChartProjection.SeriesValue> = []
        return projection.points.compactMap { point in
            guard let series = point.series, seen.insert(series).inserted else { return nil }
            return series.displayName
        }
    }

    private func pointAccessibilityLabel(_ point: ResultChartProjection.Point, series: String?) -> String {
        var components = ["\(projection.xAxisLabel): \(point.rawX)"]
        if let seriesLabel = projection.seriesLabel, let series {
            components.append("\(seriesLabel): \(series)")
        }
        return components.joined(separator: ", ")
    }

    private func pointAccessibilityValue(_ point: ResultChartProjection.Point) -> String {
        "\(projection.yAxisLabel): \(point.rawY)"
    }

    private var accessibilitySummary: String {
        String(
            format: String(localized: "%1$@ chart of %2$@ by %3$@ with %4$d points"),
            chartType.displayName,
            projection.yAxisLabel,
            projection.xAxisLabel,
            projection.points.count
        )
    }
}

#Preview("Bar chart") {
    ResultChartPreview(chartType: .bar)
}

#Preview("Line chart") {
    ResultChartPreview(chartType: .line)
}

#Preview("Area chart") {
    ResultChartPreview(chartType: .area)
}

#Preview("Scatter chart") {
    ResultChartPreview(chartType: .scatter)
}

private struct ResultChartPreview: View {
    let chartType: ResultChartType

    var body: some View {
        ResultChartCanvas(projection: projection, chartType: chartType)
            .frame(width: 900, height: 520)
            .padding()
    }

    private var projection: ResultChartProjection {
        chartType == .scatter ? numericProjection : categoricalProjection
    }

    private var categoricalProjection: ResultChartProjection {
        let values = [
            ("Jan", 42, "Online"), ("Feb", 68, "Online"),
            ("Mar", 57, "Online"), ("Apr", 84, "Online"),
            ("Jan", 29, "Retail"), ("Feb", 51, "Retail"),
            ("Mar", 46, "Retail"), ("Apr", 66, "Retail"),
        ]
        let points = values.enumerated().map { index, value in
            ResultChartProjection.Point(
                sourceIndex: index,
                x: .category(value.0),
                y: Double(value.1),
                rawX: value.0,
                rawY: String(value.1),
                series: .value(value.2),
                barGroup: value.2 == "Online" ? 0 : 1,
                lineGroup: value.2 == "Online" ? 0 : 1
            )
        }
        return ResultChartProjection(
            points: points,
            xAxisKind: .category,
            limits: [],
            loadedRowCount: points.count,
            skippedRowCount: 0,
            xAxisLabel: "Month",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel"
        )
    }

    private var numericProjection: ResultChartProjection {
        let values = [
            (12, 38, "Online"), (18, 54, "Online"),
            (26, 63, "Online"), (34, 82, "Online"),
            (10, 26, "Retail"), (17, 40, "Retail"),
            (24, 49, "Retail"), (31, 64, "Retail"),
        ]
        let points = values.enumerated().map { index, value in
            ResultChartProjection.Point(
                sourceIndex: index,
                x: .number(Double(value.0)),
                y: Double(value.1),
                rawX: String(value.0),
                rawY: String(value.1),
                series: .value(value.2),
                barGroup: value.2 == "Online" ? 0 : 1,
                lineGroup: value.2 == "Online" ? 0 : 1
            )
        }
        return ResultChartProjection(
            points: points,
            xAxisKind: .number,
            limits: [],
            loadedRowCount: points.count,
            skippedRowCount: 0,
            xAxisLabel: "Ad Spend",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel"
        )
    }
}
