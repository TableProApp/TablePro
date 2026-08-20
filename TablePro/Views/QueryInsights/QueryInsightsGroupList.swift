import SwiftUI

/// Which number leads a row. The panels share a row shape but not a headline: "most run" is about
/// the count, "slowest" about time, "failures" about how many broke.
enum QueryInsightsGroupMetric {
    case callCount
    case duration(QueryInsightsSlowestRanking)
    case failures
}

struct QueryInsightsGroupList: View {
    let groups: [QueryInsightsGroup]
    let metric: QueryInsightsGroupMetric
    let onCopy: (QueryInsightsGroup) -> Void
    let onLoadInEditor: (QueryInsightsGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider()
                }
                row(group)
            }
        }
    }

    private func row(_ group: QueryInsightsGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(headline(group))
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(headlineTint(group))
                .frame(minWidth: 76, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.normalizedQuery)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)

                Text(subtitle(group))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = group.latestErrorMessage, case .failures = metric {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline(group)). \(group.normalizedQuery). \(subtitle(group))")
        .contextMenu {
            Button(String(localized: "Copy Query")) { onCopy(group) }
            Button(String(localized: "Load in Editor")) { onLoadInEditor(group) }
        }
    }

    private func headline(_ group: QueryInsightsGroup) -> String {
        switch metric {
        case .callCount:
            return String(
                format: String(localized: "%@×", comment: "Number of times a query ran, %@ is a count"),
                group.callCount.formatted()
            )
        case .duration(.totalTime):
            return QueryDurationFormatter.string(from: group.totalDuration)
        case .duration(.averageTime):
            return QueryDurationFormatter.string(from: group.meanDuration)
        case .failures:
            return String(
                format: String(localized: "%@ failed", comment: "Failure count, %@ is a count"),
                group.failureCount.formatted()
            )
        }
    }

    private func headlineTint(_ group: QueryInsightsGroup) -> Color {
        switch metric {
        case .failures: return .orange
        case .duration: return .primary
        case .callCount: return .primary
        }
    }

    private func subtitle(_ group: QueryInsightsGroup) -> String {
        var parts: [String] = [
            String(
                format: String(localized: "ran %@×", comment: "Run count in a detail line, %@ is a count"),
                group.callCount.formatted()
            ),
            String(
                format: String(localized: "avg %@", comment: "Average duration, %@ is a duration"),
                QueryDurationFormatter.string(from: group.meanDuration)
            ),
            String(
                format: String(localized: "max %@", comment: "Longest single run, %@ is a duration"),
                QueryDurationFormatter.string(from: group.maxDuration)
            ),
        ]

        if case .duration = metric {
            parts.append(String(
                format: String(localized: "total %@", comment: "Total duration, %@ is a duration"),
                QueryDurationFormatter.string(from: group.totalDuration)
            ))
        }
        if group.totalRows > 0 {
            parts.append(String(
                format: String(localized: "%@ rows", comment: "Total rows for a query shape, %@ is a count"),
                group.totalRows.formatted()
            ))
        }
        if group.failureCount > 0, !isFailurePanel {
            parts.append(String(
                format: String(localized: "%@ failed", comment: "Failure count, %@ is a count"),
                group.failureCount.formatted()
            ))
        }
        return parts.joined(separator: " · ")
    }

    private var isFailurePanel: Bool {
        if case .failures = metric { return true }
        return false
    }
}

struct QueryInsightsRegressionList: View {
    let regressions: [QueryInsightsRegression]
    let onCopy: (String) -> Void
    let onLoadInEditor: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(regressions.enumerated()), id: \.element.id) { index, regression in
                if index > 0 {
                    Divider()
                }
                row(regression)
            }
        }
    }

    private func row(_ regression: QueryInsightsRegression) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(
                format: String(localized: "%@×", comment: "Slowdown multiple, %@ is a number"),
                regression.ratio.formatted(.number.precision(.fractionLength(1)))
            ))
            .font(.system(.callout, design: .monospaced))
            .fontWeight(.medium)
            .monospacedDigit()
            .foregroundStyle(.orange)
            .frame(minWidth: 76, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(regression.normalizedQuery)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)

                Text(detail(regression))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(regression.normalizedQuery). \(detail(regression))")
        .contextMenu {
            Button(String(localized: "Copy Query")) { onCopy(regression.representativeQuery) }
            Button(String(localized: "Load in Editor")) { onLoadInEditor(regression.representativeQuery) }
        }
    }

    private func detail(_ regression: QueryInsightsRegression) -> String {
        String(
            format: String(
                localized: "%1$@ → %2$@ · %3$@ runs before, %4$@ now",
                comment: "Regression detail: prior duration, recent duration, prior count, recent count"
            ),
            QueryDurationFormatter.string(from: regression.priorMeanDuration),
            QueryDurationFormatter.string(from: regression.recentMeanDuration),
            regression.priorCallCount.formatted(),
            regression.recentCallCount.formatted()
        )
    }
}
