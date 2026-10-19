//
//  ResultChartFacetGrid.swift
//  TablePro
//

import SwiftUI

/// How many panels sit side by side and how tall each one is. A few panels fill the pane; past
/// what fits at the minimum size the grid scrolls instead of shrinking the charts further. Rows are
/// balanced, so four panels in a pane that fits three across read as two by two, not three and one.
struct ResultChartFacetLayout: Equatable {
    static let minimumPanelWidth: CGFloat = 280
    static let minimumPanelHeight: CGFloat = 200
    static let spacing: CGFloat = 12

    let columns: Int
    let panelHeight: CGFloat

    init(panelCount: Int, size: CGSize) {
        let count = max(panelCount, 1)
        let fitting = min(count, max(Int((size.width + Self.spacing) / (Self.minimumPanelWidth + Self.spacing)), 1))
        let rows = (count + fitting - 1) / fitting
        columns = (count + rows - 1) / rows
        let available = (size.height - Self.spacing * CGFloat(rows - 1)) / CGFloat(rows)
        panelHeight = max(Self.minimumPanelHeight, available.rounded(.down))
    }
}

/// Swift Charts has no facet mark, so small multiples are one chart per facet value. Each panel is
/// drawn from the whole projection's scales and the legend is drawn once under the grid, since a
/// legend in every panel would repeat it and take a different height from each plot.
struct ResultChartFacetGrid: View {
    let projection: ResultChartProjection
    let chartType: ResultChartType
    /// Changes when a new projection lands. It resets each panel's hover, and is not applied to the
    /// scroll view, which would jump back to the top on every refresh.
    let revision: AnyHashable

    private var seriesStyle: ResultChartSeriesStyle {
        ResultChartSeriesStyle(series: projection.series)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    ResultChartFacetPanels(
                        projection: projection,
                        chartType: chartType,
                        layout: ResultChartFacetLayout(panelCount: projection.panels.count, size: proxy.size),
                        revision: revision
                    )
                }
            }

            if projection.seriesLabel != nil, !seriesStyle.isEmpty {
                ResultChartLegend(
                    title: projection.seriesLabel,
                    style: seriesStyle,
                    showsStroke: chartType == .line || chartType == .area
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result-chart-facets")
    }
}

struct ResultChartFacetPanels: View {
    let projection: ResultChartProjection
    let chartType: ResultChartType
    let layout: ResultChartFacetLayout
    let revision: AnyHashable

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: ResultChartFacetLayout.spacing, alignment: .top),
                count: layout.columns
            ),
            alignment: .leading,
            spacing: ResultChartFacetLayout.spacing
        ) {
            ForEach(Array(projection.panels.enumerated()), id: \.element.id) { index, panel in
                panelView(panel, index: index)
                    .frame(height: layout.panelHeight)
            }
        }
    }

    private func panelView(_ panel: ResultChartProjection.Panel, index: Int) -> some View {
        let title = panel.facet?.label ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            ResultChartCanvas(
                projection: projection,
                panel: panel,
                chartType: chartType,
                showsLegend: false,
                accessibilityIdentifier: "result-chart-panel-chart"
            )
            .id(revision)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(projection.facetLabel ?? ""): \(title)")
        .accessibilityIdentifier("result-chart-panel-\(index)")
    }
}
