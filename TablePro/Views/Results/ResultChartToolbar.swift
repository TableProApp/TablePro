//
//  ResultChartToolbar.swift
//  TablePro
//

import SwiftUI

struct ResultChartToolbar: View {
    @Binding var configuration: ResultChartConfiguration
    let columns: [ResultChartColumn]
    let loadedRowCount: Int
    let skippedRowCount: Int
    let hasUnloadedRows: Bool

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

                    ResultChartAxisPicker(
                        title: String(localized: "X Axis"),
                        selection: xColumnBinding,
                        columns: xColumns,
                        noneLabel: String(localized: "Row Number"),
                        accessibilityIdentifier: "result-chart-x-picker"
                    )
                    .frame(width: 170)

                    ResultChartAxisPicker(
                        title: String(localized: "Y Axis"),
                        selection: yColumnBinding,
                        columns: yColumns,
                        noneLabel: String(localized: "Choose Column"),
                        accessibilityIdentifier: "result-chart-y-picker"
                    )
                    .frame(width: 170)

                    ResultChartAxisPicker(
                        title: String(localized: "Series"),
                        selection: seriesColumnBinding,
                        columns: seriesColumns,
                        noneLabel: String(localized: "None"),
                        accessibilityIdentifier: "result-chart-series-picker"
                    )
                    .frame(width: 170)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    ResultChartTypePicker(selection: chartTypeBinding)
                        .frame(maxWidth: 400, alignment: .leading)

                    ResultChartAxisPicker(
                        title: String(localized: "X Axis"),
                        selection: xColumnBinding,
                        columns: xColumns,
                        noneLabel: String(localized: "Row Number"),
                        accessibilityIdentifier: "result-chart-x-picker"
                    )
                    ResultChartAxisPicker(
                        title: String(localized: "Y Axis"),
                        selection: yColumnBinding,
                        columns: yColumns,
                        noneLabel: String(localized: "Choose Column"),
                        accessibilityIdentifier: "result-chart-y-picker"
                    )
                    ResultChartAxisPicker(
                        title: String(localized: "Series"),
                        selection: seriesColumnBinding,
                        columns: seriesColumns,
                        noneLabel: String(localized: "None"),
                        accessibilityIdentifier: "result-chart-series-picker"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        if hasUnloadedRows {
                            Label(
                                String(localized: "More rows available"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Text("·")
                                .foregroundStyle(.quaternary)
                        }
                        Text(String(format: String(localized: "%d loaded rows"), loadedRowCount))
                            .foregroundStyle(.secondary)
                        if skippedRowCount > 0 {
                            Text("·")
                                .foregroundStyle(.quaternary)
                            Text(String(format: String(localized: "%d skipped"), skippedRowCount))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .accessibilityIdentifier("result-chart-data-scope")

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Charts use the loaded result buffer. Grid selection, Find, hidden columns, and value filters do not change the chart."))
                    .accessibilityLabel(String(localized: "Chart data scope"))
            }
            .font(.caption)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chartTypeBinding: Binding<ResultChartType> {
        Binding(
            get: { configuration.chartType },
            set: { configuration.chartType = $0 }
        )
    }

    private var xColumnBinding: Binding<Int?> {
        Binding(
            get: { configuration.xColumnIndex },
            set: { configuration.xColumnIndex = $0 }
        )
    }

    private var yColumnBinding: Binding<Int?> {
        Binding(
            get: { configuration.yColumnIndex },
            set: { configuration.yColumnIndex = $0 }
        )
    }

    private var seriesColumnBinding: Binding<Int?> {
        Binding(
            get: { configuration.seriesColumnIndex },
            set: { configuration.seriesColumnIndex = $0 }
        )
    }
}
