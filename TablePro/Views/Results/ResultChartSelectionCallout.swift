//
//  ResultChartSelectionCallout.swift
//  TablePro
//

import SwiftUI

struct ResultChartSelectionCallout: View {
    private static let maximumVisibleValues = 6

    let selection: ResultChartSelection
    let xAxisLabel: String
    let yAxisLabel: String
    let seriesLabel: String?

    private var visiblePoints: ArraySlice<ResultChartProjection.Point> {
        selection.points.prefix(Self.maximumVisibleValues)
    }

    private var remainingCount: Int {
        max(0, selection.points.count - visiblePoints.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(xAxisLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(selection.rawX)
                    .font(.callout)
                    .bold()
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Divider()

            ForEach(visiblePoints) { point in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(valueLabel(for: point))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(point.rawY)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption)
            }

            if remainingCount > 0 {
                Text(String(format: String(localized: "%d more"), remainingCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
    }

    private func valueLabel(for point: ResultChartProjection.Point) -> String {
        guard seriesLabel != nil, let series = point.series else { return yAxisLabel }
        return series.displayName
    }
}
