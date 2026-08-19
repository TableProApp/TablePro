//
//  ResultChartToolbar.swift
//  TablePro
//

import SwiftUI

struct ResultChartToolbar: View {
    @Binding var configuration: ResultChartConfiguration
    let columns: [ResultChartColumn]
    let resolved: ResultChartConfiguration.Resolved?
    let projection: ResultChartProjection?

    private var xColumns: [ResultChartColumn] {
        columns.filter { $0.xAxisKind != nil }
    }

    private var yColumns: [ResultChartColumn] {
        columns.filter(\.supportsY)
    }

    private var seriesColumns: [ResultChartColumn] {
        columns.filter(\.supportsSeries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ResultChartTypePicker(selection: chartTypeBinding)
                        .fixedSize()

                    Divider()
                        .frame(height: 22)

                    axisPickers { $0.frame(width: 170) }
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    ResultChartTypePicker(selection: chartTypeBinding)
                        .frame(maxWidth: 400, alignment: .leading)

                    axisPickers { $0 }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(notices.enumerated()), id: \.offset) { index, notice in
                            if index > 0 {
                                Text("·")
                                    .foregroundStyle(.quaternary)
                            }
                            Text(notice)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .accessibilityIdentifier("result-chart-data-scope")

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Charts draw the rows the result pane has loaded. Grid selection, Find, hidden columns, and value filters do not change the chart."))
                    .accessibilityLabel(String(localized: "Chart data scope"))
            }
            .font(.caption)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func axisPickers(_ sized: (ResultChartAxisPicker) -> some View) -> some View {
        sized(ResultChartAxisPicker(
            title: String(localized: "X Axis"),
            selection: xColumnBinding,
            columns: xColumns,
            noneLabel: String(localized: "Row Number"),
            allowsNone: true,
            accessibilityIdentifier: "result-chart-x-picker"
        ))
        sized(ResultChartAxisPicker(
            title: String(localized: "Y Axis"),
            selection: yColumnBinding,
            columns: yColumns,
            noneLabel: String(localized: "Choose Column"),
            allowsNone: false,
            accessibilityIdentifier: "result-chart-y-picker"
        ))
        sized(ResultChartAxisPicker(
            title: String(localized: "Series"),
            selection: seriesColumnBinding,
            columns: seriesColumns,
            noneLabel: String(localized: "None"),
            allowsNone: true,
            accessibilityIdentifier: "result-chart-series-picker"
        ))
    }

    /// What the chart itself has to say. The row count and the controls that load more rows belong
    /// to the status bar, which shows them in chart mode too, so repeating them here would give the
    /// same fact two different phrasings.
    private var notices: [String] {
        guard let projection else { return [] }
        var notices = projection.limits.map { Self.noticeText(for: $0, loadedRowCount: projection.loadedRowCount) }
        if projection.skippedRowCount > 0 {
            notices.append(String(format: String(localized: "%d skipped"), projection.skippedRowCount))
        }
        return notices
    }

    static func noticeText(for limit: ResultChartProjection.Limit, loadedRowCount: Int) -> String {
        switch limit {
        case .points(let limit):
            return String(
                format: String(localized: "Showing the first %1$@ points of %2$@ loaded rows"),
                grouped(limit),
                grouped(loadedRowCount)
            )
        case .series(let limit):
            return String(format: String(localized: "Showing the first %@ series"), grouped(limit))
        case .inspectedRows(let limit):
            return String(
                format: String(localized: "Charting the first %1$@ of %2$@ loaded rows"),
                grouped(limit),
                grouped(loadedRowCount)
            )
        }
    }

    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private var chartTypeBinding: Binding<ResultChartType> {
        Binding(
            get: { configuration.chartType },
            set: { configuration.chartType = $0 }
        )
    }

    /// The pickers show what the chart is actually plotting, which is the resolved column rather
    /// than the stored preference: a choice whose column is missing from this result is kept so it
    /// comes back, but it is not what the reader is looking at. With no numeric column there is no
    /// resolution to echo, so the stored preference is shown instead of snapping back to a
    /// placeholder the user did not pick.
    private var xColumnBinding: Binding<ResultChartColumnID?> {
        Binding(
            get: { resolved.map { $0.xColumn?.id } ?? configuration.xColumn },
            set: { configuration.xColumn = $0 }
        )
    }

    private var yColumnBinding: Binding<ResultChartColumnID?> {
        Binding(
            get: { resolved?.yColumn.id ?? configuration.yColumn },
            set: { configuration.yColumn = $0 }
        )
    }

    private var seriesColumnBinding: Binding<ResultChartColumnID?> {
        Binding(
            get: { resolved.map { $0.seriesColumn?.id } ?? configuration.seriesColumn },
            set: { configuration.seriesColumn = $0 }
        )
    }
}
