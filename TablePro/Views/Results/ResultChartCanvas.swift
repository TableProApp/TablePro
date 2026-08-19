//
//  ResultChartCanvas.swift
//  TablePro
//

import Charts
import SwiftUI

struct ResultChartCanvas: View {
    let projection: ResultChartProjection
    let chartType: ResultChartType

    var body: some View {
        Group {
            if case .category = projection.points.first?.x {
                categoricalChart
            } else {
                numericChart
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.55))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel {
                    if let number = value.as(Decimal.self) {
                        Text(NSDecimalNumber(decimal: number).stringValue)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.55))
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .clipShape(.rect(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("result-chart")
    }

    private var categoricalChart: some View {
        Chart(projection.points) { point in
            if case .category(let x) = point.x {
                mark(for: point, x: x)
            }
        }
        .chartLegend(projection.seriesLabel == nil ? .hidden : .visible)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
    }

    private var numericChart: some View {
        Chart(projection.points) { point in
            if case .number(let x) = point.x {
                mark(for: point, x: x)
            }
        }
        .chartLegend(projection.seriesLabel == nil ? .hidden : .visible)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
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
                .accessibilityValue(point.rawY)
            } else {
                PointMark(
                    x: .value(projection.xAxisLabel, x),
                    y: .value(projection.yAxisLabel, point.y)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(48)
                .accessibilityLabel(pointAccessibilityLabel(point, series: nil))
                .accessibilityValue(point.rawY)
            }
        }
    }

    private func seriesDisplayName(_ value: ResultChartProjection.SeriesValue?) -> String? {
        switch value {
        case .value(let raw): return raw
        case .missing: return String(localized: "No value")
        case nil: return nil
        }
    }

    private func pointAccessibilityLabel(_ point: ResultChartProjection.Point, series: String?) -> String {
        var components = [
            "\(projection.xAxisLabel): \(point.rawX)",
            "\(projection.yAxisLabel): \(point.rawY)",
        ]
        if let seriesLabel = projection.seriesLabel, let series {
            components.append("\(seriesLabel): \(series)")
        }
        return components.joined(separator: ", ")
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

#Preview("Result chart") {
    let points = [
        ResultChartProjection.Point(
            sourceIndex: 0,
            x: .category("Jan"),
            y: Decimal(42),
            rawX: "Jan",
            rawY: "42",
            series: .value("Online"),
            barGroup: 0,
            lineGroup: 0
        ),
        ResultChartProjection.Point(
            sourceIndex: 1,
            x: .category("Feb"),
            y: Decimal(68),
            rawX: "Feb",
            rawY: "68",
            series: .value("Online"),
            barGroup: 0,
            lineGroup: 0
        ),
        ResultChartProjection.Point(
            sourceIndex: 2,
            x: .category("Jan"),
            y: Decimal(29),
            rawX: "Jan",
            rawY: "29",
            series: .value("Retail"),
            barGroup: 1,
            lineGroup: 1
        ),
        ResultChartProjection.Point(
            sourceIndex: 3,
            x: .category("Feb"),
            y: Decimal(51),
            rawX: "Feb",
            rawY: "51",
            series: .value("Retail"),
            barGroup: 1,
            lineGroup: 1
        ),
    ]
    let projection = ResultChartProjection(
        points: points,
        issue: nil,
        loadedRowCount: points.count,
        skippedRowCount: 0,
        xAxisLabel: "Month",
        yAxisLabel: "Revenue",
        seriesLabel: "Channel"
    )

    ResultChartCanvas(projection: projection, chartType: .bar)
        .frame(width: 900, height: 520)
        .padding()
}
