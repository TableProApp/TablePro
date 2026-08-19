//
//  ResultChartCanvas.swift
//  TablePro
//

import Charts
import SwiftUI

struct ResultChartCanvas: View {
    let projection: ResultChartProjection
    let chartType: ResultChartType

    @State private var selectedCategory: String?
    @State private var selectedNumber: Decimal?

    var body: some View {
        Group {
            if case .category = projection.points.first?.x {
                categoricalChart
            } else {
                numericChart
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
        .onChange(of: projection) {
            selectedCategory = nil
            selectedNumber = nil
        }
    }

    private var categoricalChart: some View {
        let selection = ResultChartSelection.categorical(in: projection, selectedX: selectedCategory)
        return Chart {
            ForEach(projection.points) { point in
                if case .category(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .category(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        }
        .chartLegend(projection.seriesLabel == nil ? .hidden : .visible)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXSelection(value: $selectedCategory)
    }

    private var numericChart: some View {
        let selection = ResultChartSelection.numeric(in: projection, selectedX: selectedNumber)
        return Chart {
            ForEach(projection.points) { point in
                if case .number(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .number(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        }
        .chartLegend(projection.seriesLabel == nil ? .hidden : .visible)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXSelection(value: $selectedNumber)
    }

    @ChartContentBuilder
    private func mark<X: Plottable>(for point: ResultChartProjection.Point, x: X) -> some ChartContent {
        let series = seriesDisplayName(point.series)
        switch chartType {
        case .bar:
            if let series {
                BarMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    stacking: .unstacked
                )
                .position(by: .value(String(localized: "Row"), point.barGroup))
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .accessibilityLabel(pointAccessibilityLabel(point, series: series))
                .accessibilityValue(pointAccessibilityValue(point))
                PointMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y)
                )
                .position(by: .value(String(localized: "Row"), point.barGroup))
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbol(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbolSize(28)
                .accessibilityHidden(true)
            } else {
                BarMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    stacking: .unstacked
                )
                .position(by: .value(String(localized: "Row"), point.barGroup))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(pointAccessibilityLabel(point, series: nil))
                .accessibilityValue(pointAccessibilityValue(point))
            }
        case .line:
            if let series {
                LineMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    series: .value(String(localized: "Line"), point.lineGroup)
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .lineStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .accessibilityLabel(pointAccessibilityLabel(point, series: series))
                .accessibilityValue(pointAccessibilityValue(point))
                PointMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y)
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbol(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
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
        case .area:
            if let series {
                AreaMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    series: .value(String(localized: "Area"), point.lineGroup),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .opacity(0.18)
                .accessibilityHidden(true)
                LineMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    series: .value(String(localized: "Area"), point.lineGroup)
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .lineStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .accessibilityLabel(pointAccessibilityLabel(point, series: series))
                .accessibilityValue(pointAccessibilityValue(point))
                PointMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y)
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbol(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbolSize(42)
                .accessibilityHidden(true)
            } else {
                AreaMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    series: .value(String(localized: "Area"), point.lineGroup),
                    stacking: .unstacked
                )
                .foregroundStyle(Color.accentColor.opacity(0.18))
                .accessibilityHidden(true)
                LineMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y),
                    series: .value(String(localized: "Area"), point.lineGroup)
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
        case .scatter:
            if let series {
                PointMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y)
                )
                .foregroundStyle(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
                .symbol(by: .value(projection.seriesLabel ?? String(localized: "Series"), series))
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

    private func seriesDisplayName(_ value: ResultChartProjection.SeriesValue?) -> String? {
        switch value {
        case .value(let raw): return raw
        case .missing: return String(localized: "No value")
        case nil: return nil
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
                y: Decimal(value.1),
                rawX: value.0,
                rawY: String(value.1),
                series: .value(value.2),
                barGroup: value.2 == "Online" ? 0 : 1,
                lineGroup: value.2 == "Online" ? 0 : 1
            )
        }
        return ResultChartProjection(
            points: points,
            issue: nil,
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
                x: .number(Decimal(value.0)),
                y: Decimal(value.1),
                rawX: String(value.0),
                rawY: String(value.1),
                series: .value(value.2),
                barGroup: value.2 == "Online" ? 0 : 1,
                lineGroup: value.2 == "Online" ? 0 : 1
            )
        }
        return ResultChartProjection(
            points: points,
            issue: nil,
            loadedRowCount: points.count,
            skippedRowCount: 0,
            xAxisLabel: "Ad Spend",
            yAxisLabel: "Revenue",
            seriesLabel: "Channel"
        )
    }
}
