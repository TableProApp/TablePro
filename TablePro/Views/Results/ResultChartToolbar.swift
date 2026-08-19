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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Picker(String(localized: "Chart Type"), selection: chartTypeBinding) {
                        ForEach(ResultChartType.allCases) { type in
                            Label(type.displayName, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("result-chart-type-picker")

                    Divider()
                        .frame(height: 22)

                    axisPicker(
                        title: String(localized: "X Axis"),
                        selection: xColumnBinding,
                        columns: xColumns,
                        noneLabel: String(localized: "Row Number")
                    )

                    axisPicker(
                        title: String(localized: "Y Axis"),
                        selection: yColumnBinding,
                        columns: yColumns,
                        noneLabel: String(localized: "Choose Column")
                    )

                    axisPicker(
                        title: String(localized: "Series"),
                        selection: seriesColumnBinding,
                        columns: seriesColumns,
                        noneLabel: String(localized: "None")
                    )
                }
            }

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
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
                .accessibilityIdentifier("result-chart-data-scope")

                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Charts use the loaded result buffer. Grid selection, Find, hidden columns, and value filters do not change the chart."))
                    .accessibilityLabel(String(localized: "Chart data scope"))
                    .accessibilityValue(String(localized: "Charts use the loaded result buffer. Grid selection, Find, hidden columns, and value filters do not change the chart."))
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

    private func axisPicker(
        title: String,
        selection: Binding<Int?>,
        columns: [ResultChartColumn],
        noneLabel: String
    ) -> some View {
        Picker(title, selection: selection) {
            Text(noneLabel).tag(Int?.none)
            ForEach(columns) { column in
                Text(column.displayName).tag(Optional(column.index))
            }
        }
        .frame(width: 170)
    }
}
