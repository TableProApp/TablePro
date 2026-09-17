import SwiftUI

struct QueryInsightsSummaryBar: View {
    let totals: QueryInsightsTotals

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            metric(
                label: String(localized: "Queries"),
                value: totals.totalCount.formatted(),
                detail: String(
                    format: String(
                        localized: "%@ shapes",
                        comment: "Number of distinct query shapes, %@ is a count"
                    ),
                    totals.distinctShapeCount.formatted()
                ),
                systemImage: "number",
                tint: .secondary
            )
            metric(
                label: String(localized: "Failed"),
                value: totals.failureRate.formatted(.percent.precision(.fractionLength(0...1))),
                detail: String(
                    format: String(
                        localized: "%@ of %@",
                        comment: "Failed count out of total, both are counts"
                    ),
                    totals.failedCount.formatted(),
                    totals.totalCount.formatted()
                ),
                systemImage: "exclamationmark.triangle",
                tint: totals.failedCount > 0 ? .orange : .secondary
            )
            metric(
                label: String(localized: "Average"),
                value: QueryDurationFormatter.string(from: totals.meanDuration),
                detail: String(
                    format: String(localized: "%@ slowest", comment: "Slowest single run, %@ is a duration"),
                    QueryDurationFormatter.string(from: totals.maxDuration)
                ),
                systemImage: "gauge.with.needle",
                tint: .secondary
            )
            metric(
                label: String(localized: "Total Time"),
                value: QueryDurationFormatter.string(from: totals.totalDuration),
                detail: String(localized: "Time spent waiting"),
                systemImage: "clock",
                tint: .secondary
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metric(
        label: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Text(value)
                .font(.title2)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(detail)")
    }
}
