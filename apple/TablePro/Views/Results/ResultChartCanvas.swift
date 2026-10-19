//
//  ResultChartCanvas.swift
//  TablePro
//

import Charts
import SwiftUI
import TableProTheme

struct ResultChartCanvas: View {
    let projection: ResultChartProjection
    let chartType: ResultChartType

    private let panel: ResultChartProjection.Panel
    private let slotSeeds: [Int]
    private let showsLegend: Bool
    private let accessibilityIdentifier: String
    private let selectionIndex: ResultChartSelectionIndex
    private let seriesStyle: ResultChartSeriesStyle

    @State private var selectedCategory: String?
    @State private var selectedNumber: Double?
    @State private var selectedDate: Date?
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    /// Draws one panel of the projection, every panel when it is not faceted. The axes, colours,
    /// symbols and dashes come from the whole projection, so the panels of one grid line up.
    init(
        projection: ResultChartProjection,
        panel: ResultChartProjection.Panel? = nil,
        chartType: ResultChartType,
        showsLegend: Bool = true,
        accessibilityIdentifier: String = "result-chart"
    ) {
        self.projection = projection
        self.chartType = chartType
        let panel = panel ?? ResultChartProjection.Panel(facet: nil, points: projection.points)
        self.panel = panel
        slotSeeds = chartType == .bar && projection.isFaceted
            ? Array(Set(projection.points.map(\.barGroup))).sorted()
            : []
        self.showsLegend = showsLegend
        self.accessibilityIdentifier = accessibilityIdentifier
        selectionIndex = ResultChartSelectionIndex(points: panel.points)
        seriesStyle = ResultChartSeriesStyle(series: projection.series)
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
                    .foregroundStyle(gridLineStyle)
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(tickStyle)
                AxisValueLabel()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(gridLineStyle)
                AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(tickStyle)
                AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 8))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
        .modifier(SharedAxes(
            domain: projection.domain,
            xAxisKind: projection.xAxisKind,
            sharesXAxis: projection.sharesXAxis
        ))
        .chartPlotStyle { plotArea in
            plotArea
                .themeBackground(
                    .gridBackground,
                    native: Color(nsColor: .controlBackgroundColor).opacity(0.45),
                    in: .rect(cornerRadius: 8)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// The chart stands where the grid would, so its plot takes the grid's background and lines.
    private var gridLineStyle: AnyShapeStyle {
        ThemeShapeStyle.style(
            .gridLine,
            native: Color(nsColor: .separatorColor).opacity(0.55),
            engine: themeEngine,
            contrast: contrast
        )
    }

    private var tickStyle: AnyShapeStyle {
        ThemeShapeStyle.style(.gridLine, native: Color(nsColor: .separatorColor), engine: themeEngine, contrast: contrast)
    }

    private var categoricalChart: some View {
        let selection = selectionIndex.selection(forCategory: selectedCategory)
        return legend(Chart {
            if case .category(let x)? = panel.points.first?.x {
                ForEach(slotSeeds, id: \.self) { slotSeed($0, x: x) }
            }
            ForEach(panel.points) { point in
                if case .category(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .category(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelectionCompat(value: $selectedCategory)
    }

    private var numericChart: some View {
        let selection = selectionIndex.selection(nearestNumber: selectedNumber)
        return legend(Chart {
            if case .number(let x)? = panel.points.first?.x {
                ForEach(slotSeeds, id: \.self) { slotSeed($0, x: x) }
            }
            ForEach(panel.points) { point in
                if case .number(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .number(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelectionCompat(value: $selectedNumber)
    }

    private var dateChart: some View {
        let selection = selectionIndex.selection(nearestDate: selectedDate)
        return legend(Chart {
            if case .date(let x)? = panel.points.first?.x {
                ForEach(slotSeeds, id: \.self) { slotSeed($0, x: x) }
            }
            ForEach(panel.points) { point in
                if case .date(let x) = point.x {
                    mark(for: point, x: x)
                }
            }
            if let selection, case .date(let x) = selection.x {
                selectionMark(at: x, selection: selection)
            }
        })
        .chartXSelectionCompat(value: $selectedDate)
    }

    /// Every scale takes its domain from the whole projection: a panel infers its own otherwise, so
    /// one series would change colour between panels, and every series whenever the rows are
    /// re-sorted. The per-series stroke lives on the line-style scale, not on the mark: a constant
    /// `lineStyle` applied after `lineStyle(by:)` replaces it, which leaves colour as the only thing
    /// telling two series apart.
    @ViewBuilder
    private func legend(_ chart: some View) -> some View {
        let styled = chart
            .chartLegend(showsLegend && projection.seriesLabel != nil ? .visible : .hidden)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        if seriesStyle.isEmpty {
            styled
        } else {
            styled
                .chartForegroundStyleScale(domain: seriesStyle.names, range: seriesStyle.colors)
                .chartSymbolScale(domain: seriesStyle.names, range: seriesStyle.symbols)
                .chartLineStyleScale(domain: seriesStyle.names, range: seriesStyle.strokes)
        }
    }

    @ChartContentBuilder
    private func mark<X: Plottable>(for point: ResultChartProjection.Point, x: X) -> some ChartContent {
        let series = point.series?.label
        switch chartType {
        case .bar: barMark(for: point, x: x, series: series)
        case .line: lineMark(for: point, x: x, series: series)
        case .area: areaMark(for: point, x: x, series: series)
        case .scatter: scatterMark(for: point, x: x, series: series)
        }
    }

    /// The grouping dimension is a slot, so its value has to be discrete. Swift Charts reads an
    /// `Int` as a continuous offset, which drops a repeated category's second bar into the next
    /// category's band. The scale orders discrete slots by first appearance in the chart's marks,
    /// which the projection numbers in that order; a faceted panel names every slot up front
    /// (`slotSeed`), so a panel whose rows name a later series first still puts each where the
    /// other panels do.
    private func slot(_ point: ResultChartProjection.Point) -> PlottableValue<String> {
        .value(String(localized: "Row"), String(point.barGroup))
    }

    private func seriesValue(_ series: String) -> PlottableValue<String> {
        .value(projection.seriesLabel ?? String(localized: "Series"), series)
    }

    /// `position(by:)` divides each band among the slots this chart's marks name, in the order they
    /// first appear, and has no domain to pass. A panel missing a series, or naming a later one
    /// first, would draw its bars wider or swapped, so every slot of the whole projection is named
    /// once, in order, by an invisible zero-height bar ahead of the real ones. Measured: a sparse
    /// panel's bars then land at the full panel's positions and widths.
    @ChartContentBuilder
    private func slotSeed<X: Plottable>(_ slot: Int, x: X) -> some ChartContent {
        BarMark(
            x: .value(projection.xAxisLabel, x),
            y: .value(projection.yAxisLabel, 0),
            stacking: .unstacked
        )
        .position(by: .value(String(localized: "Row"), String(slot)))
        .opacity(0)
        .accessibilityHidden(true)
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
        if #available(macOS 14.0, *) {
            RuleMark(x: .value(projection.xAxisLabel, x))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(
                    position: .top,
                    alignment: .leading,
                    spacing: 8,
                    overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    callout(for: selection)
                }
                .accessibilityHidden(true)
        } else {
            /// `overflowResolution` is macOS 14. Without it the callout can run past the plot
            /// edge at the extremes of the axis; the position and spacing are unchanged.
            RuleMark(x: .value(projection.xAxisLabel, x))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading, spacing: 8) {
                    callout(for: selection)
                }
                .accessibilityHidden(true)
        }
    }

    private func callout(for selection: ResultChartSelection) -> some View {
        ResultChartSelectionCallout(
            selection: selection,
            xAxisLabel: projection.xAxisLabel,
            yAxisLabel: projection.yAxisLabel,
            seriesLabel: projection.seriesLabel
        )
    }

    private func pointAccessibilityLabel(_ point: ResultChartProjection.Point, series: String?) -> String {
        var components = ["\(projection.xAxisLabel): \(point.xLabel)"]
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
            panel.points.count
        )
    }
}

/// The panels of a faceted chart are separate charts, so each is given the extent of every panel's
/// data instead of inferring its own. Numbers keep Swift Charts' own rounding and zero baseline:
/// the shared extent is appended to what it infers, which a single chart already contains.
private struct SharedAxes: ViewModifier {
    let domain: ResultChartProjection.Domain
    let xAxisKind: ResultChartColumn.AxisKind
    let sharesXAxis: Bool

    func body(content: Content) -> some View {
        sharedX(content).chartYScale(domain: Self.including(domain.y))
    }

    @ViewBuilder
    private func sharedX(_ content: Content) -> some View {
        if !sharesXAxis {
            content
        } else {
            sharedDomainX(content)
        }
    }

    @ViewBuilder
    private func sharedDomainX(_ content: Content) -> some View {
        switch xAxisKind {
        case .category:
            content.chartXScale(domain: domain.categories)
        case .number:
            content.chartXScale(domain: Self.including(domain.numbers))
        case .date:
            if let dates = domain.dates, dates.lowerBound < dates.upperBound {
                content.chartXScale(domain: dates)
            } else {
                content
            }
        }
    }

    private static func including(_ extent: ClosedRange<Double>?) -> AutomaticScaleDomain {
        guard let extent else { return .automatic }
        return .automatic(dataType: Double.self) { inferred in
            inferred.append(contentsOf: [extent.lowerBound, extent.upperBound])
        }
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
                series: .init(.value(value.2)),
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
                series: .init(.value(value.2)),
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
